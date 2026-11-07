import Config

config :belgo, release_name: Box.Config.get("RELEASE_NAME")

if config_env() == :prod do
  config :logger,
    level:
      (case Box.Config.get("BELGO_LOG_LEVEL", default: "info") do
         "debug" -> :debug
         "info" -> :info
         "warning" -> :warning
         "error" -> :error
       end)
end

data_path =
  Box.Config.get!("BELGO_DATA_PATH", test: Path.expand("../tmp/test_inventory", __DIR__))

config :belgo, Belgo.Inventory, storage: {Belgo.Inventory.Storage.YamlDirectory, path: data_path}

config :belgo, Belgo.Config, directory: data_path
config :belgo, Belgo.Reachability, directory: data_path
config :belgo, Belgo.Versioning, directory: data_path
config :belgo, Belgo.PortScan, directory: data_path

config :belgo, Belgo.Discovery,
  directory: data_path,
  refresh_on_start: config_env() != :test

config :belgo, BelgoWeb.Authentication,
  # Tests always use the static user, whatever the developer's environment says.
  mode:
    (case Box.Config.get("BELGO_AUTHENTICATION", default: "trusted_headers", test: "static") do
       "trusted_headers" -> :trusted_headers
       "static" -> :static
     end),
  static_user: [
    username: Box.Config.get("BELGO_STATIC_USERNAME", default: "admin"),
    name: Box.Config.get("BELGO_STATIC_NAME", default: "Administrator")
  ]

app_host = Box.Config.uri("APP_HOST", default: "http://localhost:4000")
port = Box.Config.int("PORT", default: "4000")

config :belgo, BelgoWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: port],
  url: [host: app_host.host, scheme: app_host.scheme, port: app_host.port],
  # Test values: the test environment needs no variable (CI, fresh shells).
  secret_key_base:
    Box.Config.get!("SECRET_KEY_BASE",
      test: "test-only-secret-key-base-of-at-least-sixty-four-bytes-0123456789abcdef"
    ),
  live_view: [
    signing_salt: Box.Config.get!("LIVE_VIEW_SALT", test: "test-only-signing-salt")
  ]
