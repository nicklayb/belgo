import Config

config :belgo, BelgoWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info

config :belgo, BelgoWeb.Endpoint, server: true
