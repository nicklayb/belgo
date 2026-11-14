defmodule Belgo.Providers.Omada do
  @moduledoc """
  TP-Link Omada provider (software controller).

  Uses the official Open API (client credentials, see `Omada.HttpClient`). Reads the
  site devices (gateway, switches, access points with their uplink) and the
  connected clients (MAC, IP, the switch port or access point they use, Wi-Fi details,
  "Lock to AP", recognised type, vendor and model). Pushes rename clients after their
  Belgo device and set their type, vendor and model (`Omada.Push`): Omada only knows
  clients it has seen, so nothing is created and nothing is deleted. Wireless
  clients can be reconnected on demand (`reconnect_client/2`, write mode).

  Options in `providers.yaml`:

    * `url` – base URL of the controller, e.g. `https://omada.home.lan:8043` (required)
    * `omada_id` – the Omada ID shown with the Open API application; read from
      `/api/info` when omitted
    * `site` – site name, defaults to `Default`
    * `verify_tls` – verify the certificate, defaults to `true`

  Secrets: `BELGO_OMADA_CLIENT_ID` and `BELGO_OMADA_CLIENT_SECRET` (or `*_FILE`), from
  an Open API application in client mode (Settings > Platform Integration > Open API);
  its permissions must allow editing clients for pushes. Optional
  `BELGO_OMADA_USERNAME` and `BELGO_OMADA_PASSWORD`: a controller account for its web
  API, the only way to set a client's type, vendor and model (skipped without them).
  """

  @behaviour Belgo.Providers.Provider

  alias Belgo.Discovery.Report
  alias Belgo.Providers.Omada.Push
  alias Belgo.Providers.Omada.Translate
  alias Belgo.Providers.Options
  alias Belgo.Providers.Secrets
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.PushReport

  @option_names ~w(url omada_id site verify_tls)
  @default_site "Default"
  @client_id_secret "BELGO_OMADA_CLIENT_ID"
  @client_secret_secret "BELGO_OMADA_CLIENT_SECRET"
  @username_secret "BELGO_OMADA_USERNAME"
  @password_secret "BELGO_OMADA_PASSWORD"

  defmodule Config do
    @moduledoc "Connection settings of an Omada controller."
    @enforce_keys [:url, :client_id, :client_secret]
    defstruct [
      :url,
      :client_id,
      :client_secret,
      :omada_id,
      :username,
      :password,
      site: "Default",
      verify_tls: true,
      client: Belgo.Providers.Omada.HttpClient
    ]

    @type t :: %__MODULE__{
            url: String.t(),
            client_id: String.t(),
            client_secret: String.t(),
            omada_id: String.t() | nil,
            username: String.t() | nil,
            password: String.t() | nil,
            site: String.t(),
            verify_tls: boolean(),
            client: module()
          }
  end

  defimpl Inspect, for: Config do
    def inspect(config, _options),
      do: "#Belgo.Providers.Omada.Config<url: #{config.url}, site: #{config.site}>"
  end

  @impl Belgo.Providers.Provider
  def key, do: :omada

  @impl Belgo.Providers.Provider
  def label, do: "Omada"

  @impl Belgo.Providers.Provider
  def parse_config(options, environment) do
    Options.build(Config,
      options: Options.validate_names(options, @option_names),
      url: Options.url(options["url"]),
      site: site(Map.get(options, "site", @default_site)),
      omada_id: omada_id(Map.get(options, "omada_id")),
      verify_tls: Options.boolean(Map.get(options, "verify_tls", true), "verify_tls"),
      client_id: Secrets.fetch(@client_id_secret, environment),
      client_secret: Secrets.fetch(@client_secret_secret, environment),
      username: Secrets.fetch_optional(@username_secret, environment),
      password: Secrets.fetch_optional(@password_secret, environment),
      client: {:ok, client()}
    )
  end

  @impl Belgo.Providers.Provider
  def discover(%Config{client: client} = config) do
    with {:ok, session} <- client.open(config) do
      report(
        devices:
          with({:ok, devices} <- client.devices(session), do: {:ok, Translate.devices(devices)}),
        clients:
          with({:ok, clients} <- client.clients(session), do: {:ok, Translate.clients(clients)})
      )
    end
  end

  defp report(results) do
    failures = for {part, {:error, reason}} <- results, do: {part, reason}

    observations =
      for {_part, {:ok, observations}} <- results, observation <- observations, do: observation

    if length(failures) == length(results),
      do: {:error, failures},
      else: {:ok, Report.new(key(), observations, failures)}
  end

  @impl Belgo.Providers.Provider
  def push(%Config{}, %DesiredState{client_names: []}),
    do: {:ok, %PushReport{provider: key(), operations: [], skipped: []}}

  def push(%Config{client: client} = config, %DesiredState{} = desired_state) do
    with {:ok, session} <- client.open(config),
         {:ok, clients} <- client.clients(session),
         plan =
           Push.plan(desired_state, clients,
             types: types(client, session),
             web_access?: web_access?(config)
           ),
         :ok <- apply_operations(config, session, plan.operations) do
      {:ok, %PushReport{provider: key(), operations: plan.operations, skipped: plan.skipped}}
    end
  end

  # Without the type list, types are never sent (vendor and model still are).
  defp types(client, session) do
    case client.correction_types(session) do
      {:ok, types} -> types
      {:error, _reason} -> []
    end
  end

  defp web_access?(%Config{username: username, password: password}),
    do: is_binary(username) and is_binary(password)

  # The web session is opened once, by the first correction.
  defp apply_operations(%Config{} = config, session, operations) do
    result =
      Enum.reduce_while(operations, {:ok, nil}, fn operation, {:ok, web_session} ->
        case apply_operation(config, session, web_session, operation) do
          {:ok, web_session} -> {:cont, {:ok, web_session}}
          {:error, reason} -> {:halt, {:error, {:failed, operation.summary, reason}}}
        end
      end)

    with {:ok, _web_session} <- result, do: :ok
  end

  defp apply_operation(config, session, web_session, %Push.Operation{action: :rename} = operation) do
    with {:ok, _result} <-
           config.client.rename_client(session, operation.client_mac, operation.name),
         do: {:ok, web_session}
  end

  defp apply_operation(
         config,
         session,
         web_session,
         %Push.Operation{action: :correct} = operation
       ) do
    body = %{name: operation.name, clientInfoCorrection: operation.correction}

    with {:ok, web_session} <- open_web(config, session, web_session),
         {:ok, _result} <- config.client.correct_client(web_session, operation.client_mac, body),
         do: {:ok, web_session}
  end

  defp open_web(config, session, nil), do: config.client.open_web(config, session)
  defp open_web(_config, _session, web_session), do: {:ok, web_session}

  @impl Belgo.Providers.Provider
  def reconnect_client(%Config{client: client} = config, mac) do
    with {:ok, session} <- client.open(config),
         {:ok, _result} <- client.reconnect_client(session, mac) do
      :ok
    end
  end

  defp omada_id(nil), do: {:ok, nil}
  defp omada_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp omada_id(_id), do: {:error, "omada_id must be the Omada ID of the controller"}

  defp site(name) when is_binary(name) and name != "", do: {:ok, name}
  defp site(_name), do: {:error, "site must be a site name"}

  defp client do
    :belgo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:client, Belgo.Providers.Omada.HttpClient)
  end
end
