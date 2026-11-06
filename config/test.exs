import Config

config :belgo, BelgoWeb.Endpoint, server: false

config :logger, level: :warning

config :phoenix, :plug_init_mode, :runtime

config :belgo, Belgo.Providers.Opnsense, client: Belgo.Fixtures.OpnsenseClient
config :belgo, Belgo.Providers.Adguard, client: Belgo.Fixtures.AdguardClient
config :belgo, Belgo.Providers.Omada, client: Belgo.Fixtures.OmadaClient
config :belgo, Belgo.Providers.HomeAssistant, client: Belgo.Fixtures.HomeAssistantClient

config :belgo, Belgo.Discovery,
  environment: %{
    "BELGO_OPNSENSE_API_KEY" => "homer",
    "BELGO_OPNSENSE_API_SECRET" => "donuts",
    "BELGO_ADGUARD_USERNAME" => "marge",
    "BELGO_ADGUARD_PASSWORD" => "pretzels",
    "BELGO_OMADA_CLIENT_ID" => "ned",
    "BELGO_OMADA_CLIENT_SECRET" => "okilydokily",
    "BELGO_HOME_ASSISTANT_TOKEN" => "mmm-donuts"
  }

config :belgo, Belgo.Reachability, ping: &Belgo.Fixtures.Pinger.ping/2

config :belgo, Belgo.PortScan, scan: &Belgo.Fixtures.PortScanner.open_ports/3

config :belgo, Belgo.WakeOnLan,
  send: &Belgo.Fixtures.WakeOnLan.send_packet/2,
  ping: &Belgo.Fixtures.Pinger.ping/2
