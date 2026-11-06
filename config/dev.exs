import Config

config :belgo, BelgoWeb.Endpoint,
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:belgo, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:belgo, ~w(--watch)]}
  ]

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime
