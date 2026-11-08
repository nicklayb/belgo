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
        # Single source of the version, shared with mix.exs, the Justfile and CI.
        version = lib.strings.trim (builtins.readFile ./VERSION);

        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./VERSION
            ./mix.exs
            ./mix.lock
            ./config
            ./lib
            ./assets
            ./priv
          ];
        };

        # Browser dependencies (assets/package.json): every package is fetched by the
        # integrity hash of the lock file, no npm install at build or run time.
        nodeModules = pkgs.importNpmLock.buildNodeModules {
          npmRoot = lib.fileset.toSource {
            root = ./assets;
            fileset = lib.fileset.unions [
              ./assets/package.json
              ./assets/package-lock.json
            ];
          };
          nodejs = pkgs.nodejs;
        };

        mixFodDeps = beamPackages.fetchMixDeps {
          pname = "belgo-mix-deps";
          inherit version src;
          inherit elixir;
          hash = "sha256-rAf5GtycYsN2U2VlksPpXOZ0jArS2vNzVFDML54uZ4c=";
        };

        belgo = beamPackages.mixRelease {
          pname = "belgo";
          inherit version src mixFodDeps;
          inherit elixir;

          TAILWIND_PATH = "${pkgs.tailwindcss_4}/bin/tailwindcss";
          ESBUILD_PATH = "${pkgs.esbuild}/bin/esbuild";

          preBuild = ''
            ln -sfn ${nodeModules}/node_modules assets/node_modules
          '';

          postBuild = ''
            mix do deps.loadpaths --no-deps-check, assets.deploy
          '';
        };

        # Helm with the unit test plugin, for the chart in charts/belgo.
        helm = pkgs.wrapHelm pkgs.kubernetes-helm {
          plugins = [ pkgs.kubernetes-helmPlugins.helm-unittest ];
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
              # Nix's git (curl) does not look in /etc/ssl: without it, HTTPS remotes
              # fail with "unable to get local issuer certificate".
              "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
              "PORT=4000"
              "BELGO_DATA_PATH=/data"
              # iputils ping (busybox also ships one); needs unprivileged ICMP
              # (net.ipv4.ping_group_range) or CAP_NET_RAW.
              "BELGO_PING_PATH=${pkgs.iputils}/bin/ping"
              # Versioning of /data (`git` in config.yaml); SSH remotes use GIT_SSH,
              # overridable with GIT_SSH_COMMAND (keys, known_hosts).
              "BELGO_GIT_PATH=${pkgs.gitMinimal}/bin/git"
              "GIT_SSH=${pkgs.openssh}/bin/ssh"
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
            pkgs.git
            pkgs.nodejs
            helm
            pkgs.kubeconform
          ];

          shellHook = ''
            export MIX_HOME=$PWD/.nix-mix
            export HEX_HOME=$PWD/.nix-hex

            export TAILWIND_PATH=${pkgs.tailwindcss_4}/bin/tailwindcss
            export ESBUILD_PATH=${pkgs.esbuild}/bin/esbuild

            mix deps.get
            # Browser dependencies built by Nix from assets/package-lock.json.
            if [ ! -e assets/node_modules ] || [ -L assets/node_modules ]; then
              ln -sfn ${nodeModules}/node_modules assets/node_modules
            fi
            eval "$(direnv hook bash)"
          '';
        };
      }
    );
}
