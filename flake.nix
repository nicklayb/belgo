{
  description = "Belgo, an all-in-one homelab manager";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;
        beamPackages = pkgs.beam28Packages;
        # Move to 1.20 once it is officially released everywhere.
        elixir = beamPackages.elixir_1_19;
        version = "0.1.0";

        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./mix.exs
            ./mix.lock
            ./config
            ./lib
            ./assets
            ./priv
          ];
        };

        mixFodDeps = beamPackages.fetchMixDeps {
          pname = "belgo-mix-deps";
          inherit version src;
          inherit elixir;
          hash = "sha256-xQhMF+ikvPzyD70fQDJzamqqsJBQ6o39IaXmwzE1rJk=";
        };

        belgo = beamPackages.mixRelease {
          pname = "belgo";
          inherit version src mixFodDeps;
          inherit elixir;

          TAILWIND_PATH = "${pkgs.tailwindcss_4}/bin/tailwindcss";
          ESBUILD_PATH = "${pkgs.esbuild}/bin/esbuild";

          postBuild = ''
            mix do deps.loadpaths --no-deps-check, assets.deploy
          '';
        };

        dockerImage = pkgs.dockerTools.buildLayeredImage {
          name = "belgo";
          tag = version;
          contents = [
            pkgs.cacert
            pkgs.busybox
          ];
          extraCommands = ''
            mkdir -p -m 1777 tmp
            mkdir -p data
          '';
          config = {
            Cmd = [
              "${belgo}/bin/belgo"
              "start"
            ];
            Env = [
              "LANG=C.UTF-8"
              "PORT=4000"
              "BELGO_DATA_PATH=/data"
              # iputils ping (busybox also ships one); needs unprivileged ICMP
              # (net.ipv4.ping_group_range) or CAP_NET_RAW.
              "BELGO_PING_PATH=${pkgs.iputils}/bin/ping"
              "RELEASE_TMP=/tmp"
              "RELEASE_DISTRIBUTION=none"
              # Required by the release script, meaningless without distribution.
              "RELEASE_COOKIE=belgo-without-distribution"
            ];
            ExposedPorts."4000/tcp" = { };
            Volumes."/data" = { };
            User = "65534:65534";
          };
        };
      in
      {
        packages = {
          default = belgo;
          inherit belgo dockerImage;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            elixir
            beamPackages.erlang
            beamPackages.elixir-ls
            pkgs.direnv
            pkgs.inotify-tools
            pkgs.just
            pkgs.tailwindcss_4
            pkgs.esbuild
            pkgs.iputils
          ];

          shellHook = ''
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex

            export TAILWIND_PATH=${pkgs.tailwindcss_4}/bin/tailwindcss
            export ESBUILD_PATH=${pkgs.esbuild}/bin/esbuild

            mix deps.get
            eval "$(direnv hook bash)"
          '';
        };
      }
    );
}
