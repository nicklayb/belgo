defmodule Belgo.Providers.HomeAssistant do
  @moduledoc """
  Home Assistant provider, read only: its floors and areas are suggested as
  locations (floors as `floor`, areas as `room` inside their floor).

  The registries are read through the WebSocket API (`config/floor_registry/list`,
  `config/area_registry/list`), which does not require an administrator, unlike
  `POST /api/template`.

  Options in `providers.yaml`:

    * `url` – base URL, e.g. `https://homeassistant.home.lan:8123` (required)
    * `verify_tls` – verify the certificate, defaults to `true`

  Secret: `BELGO_HOME_ASSISTANT_TOKEN` (or `BELGO_HOME_ASSISTANT_TOKEN_FILE`), a
  long-lived access token (profile > Security), a non administrator user is enough.
  """

  @behaviour Belgo.Providers.Provider

  alias Belgo.Discovery.Report
  alias Belgo.Providers.HomeAssistant.Translate
  alias Belgo.Providers.Options
  alias Belgo.Providers.Secrets

  @option_names ~w(url verify_tls)
  @token_secret "BELGO_HOME_ASSISTANT_TOKEN"

  defmodule Config do
    @moduledoc "Connection settings of a Home Assistant instance."
    @enforce_keys [:url, :token]
    defstruct [
      :url,
      :token,
      verify_tls: true,
      client: Belgo.Providers.HomeAssistant.WebSocketClient
    ]

    @type t :: %__MODULE__{
            url: String.t(),
            token: String.t(),
            verify_tls: boolean(),
            client: module()
          }
  end

  defimpl Inspect, for: Config do
    def inspect(config, _options),
      do: "#Belgo.Providers.HomeAssistant.Config<url: #{config.url}>"
  end

  @impl Belgo.Providers.Provider
  def key, do: :home_assistant

  @impl Belgo.Providers.Provider
  def label, do: "Home Assistant"

  @impl Belgo.Providers.Provider
  def parse_config(options, environment) do
    Options.build(Config,
      options: Options.validate_names(options, @option_names),
      url: Options.url(options["url"]),
      verify_tls: Options.boolean(Map.get(options, "verify_tls", true), "verify_tls"),
      token: Secrets.fetch(@token_secret, environment),
      client: {:ok, client()}
    )
  end

  @impl Belgo.Providers.Provider
  def discover(%Config{client: client} = config) do
    with {:ok, %{floors: floors, areas: areas}} <- client.registries(config) do
      {:ok, Report.new(key(), Translate.floors(floors) ++ Translate.areas(areas))}
    end
  end

  defp client do
    :belgo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:client, Belgo.Providers.HomeAssistant.WebSocketClient)
  end
end
