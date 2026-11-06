import Config

config :belgo, environment: config_env()

config :belgo, BelgoWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: BelgoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Belgo.PubSub

config :esbuild,
  version: "0.27.2",
  belgo: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => System.get_env("MIX_DEPS_PATH", Path.expand("../deps", __DIR__))}
  ],
  path: System.get_env("ESBUILD_PATH")

config :tailwind,
  version: "4.2.3",
  belgo: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ],
  path: System.get_env("TAILWIND_PATH")

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
