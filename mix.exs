defmodule Belgo.MixProject do
  use Mix.Project

  # The project version lives in VERSION (also read by flake.nix, the Justfile and
  # the release workflow).
  @version "VERSION" |> File.read!() |> String.trim()

  def project do
    [
      app: :belgo,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader],
      releases: [belgo: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      mod: {Belgo.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  @test_inventory_path "tmp/test_inventory"

  # The application loads the test inventory at boot: start every run from scratch.
  defp remove_test_inventory(_arguments), do: File.rm_rf!(@test_inventory_path)

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.10"},
      {:box, git: "https://github.com/nicklayb/box_ex.git", tag: "0.19.0"},
      {:credo, "~> 1.7.18", runtime: false, only: ~w(dev test)a},
      {:ecto, "~> 3.13"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:mint_web_socket, "~> 1.0"},
      {:phoenix, "~> 1.8.5"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_live_view, "~> 1.1.28"},
      {:plug, "~> 1.18"},
      {:req, "~> 0.7"},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:yaml_elixir, "~> 2.11"},
      {:ymlr, "~> 5.1"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.build"],
      test: [&remove_test_inventory/1, "test"],
      "assets.build": ["tailwind belgo", "esbuild belgo"],
      "assets.deploy": [
        "tailwind belgo --minify",
        "esbuild belgo --minify",
        "phx.digest"
      ],
      gettext: [
        "gettext.extract",
        "gettext.merge priv/gettext"
      ]
    ]
  end
end
