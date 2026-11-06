defmodule Belgo.Providers.Adguard do
  @moduledoc """
  AdGuard Home provider.

  Reads persistent clients (joined to devices by MAC and IP address), automatic
  clients (seen by AdGuard Home through ARP, rDNS, DHCP…, joined by IP) and DNS
  rewrites (joined by IP and name).

  Pushes write persistent clients only (see `Belgo.Providers.Adguard.Push`): missing
  ones are added, differing ones updated, none deleted. DNS rewrites are never
  written.

  Options in `providers.yaml`:

    * `url` – base URL of the web UI, e.g. `https://adguard.home.lan` (required)
    * `verify_tls` – verify the certificate, defaults to `true`

  Secrets: `BELGO_ADGUARD_USERNAME` and `BELGO_ADGUARD_PASSWORD` (or `*_FILE`).
  """

  @behaviour Belgo.Providers.Provider

  alias Belgo.Discovery.Report
  alias Belgo.Providers.Adguard.Push
  alias Belgo.Providers.Adguard.Translate
  alias Belgo.Providers.Options
  alias Belgo.Providers.Secrets
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.PushReport

  @option_names ~w(url verify_tls)
  @username_secret "BELGO_ADGUARD_USERNAME"
  @password_secret "BELGO_ADGUARD_PASSWORD"
  @rewrites_path "/control/rewrite/list"
  @clients_path "/control/clients"

  defmodule Config do
    @moduledoc "Connection settings of an AdGuard Home instance."
    @enforce_keys [:url, :username, :password]
    defstruct [
      :url,
      :username,
      :password,
      verify_tls: true,
      client: Belgo.Providers.Adguard.HttpClient
    ]

    @type t :: %__MODULE__{
            url: String.t(),
            username: String.t(),
            password: String.t(),
            verify_tls: boolean(),
            client: module()
          }
  end

  defimpl Inspect, for: Config do
    def inspect(config, _options), do: "#Belgo.Providers.Adguard.Config<url: #{config.url}>"
  end

  @impl Belgo.Providers.Provider
  def key, do: :adguard

  @impl Belgo.Providers.Provider
  def label, do: "AdGuard Home"

  @impl Belgo.Providers.Provider
  def parse_config(options, environment) do
    Options.build(Config,
      options: Options.validate_names(options, @option_names),
      url: Options.url(options["url"]),
      verify_tls: Options.boolean(Map.get(options, "verify_tls", true), "verify_tls"),
      username: Secrets.fetch(@username_secret, environment),
      password: Secrets.fetch(@password_secret, environment),
      client: {:ok, client()}
    )
  end

  @impl Belgo.Providers.Provider
  def discover(%Config{client: client} = config) do
    results = [
      rewrites:
        with(
          {:ok, rows} <- client.get(config, @rewrites_path),
          do: {:ok, Translate.rewrites(rows)}
        ),
      clients:
        with({:ok, body} <- client.get(config, @clients_path), do: {:ok, Translate.clients(body)})
    ]

    failures = for {part, {:error, reason}} <- results, do: {part, reason}

    case failures do
      [_rewrites, _clients] ->
        {:error, failures}

      _partial_or_none ->
        observations =
          for {_part, {:ok, observations}} <- results,
              observation <- observations,
              do: observation

        {:ok, Report.new(key(), observations, failures)}
    end
  end

  @impl Belgo.Providers.Provider
  def push(%Config{client: client} = config, %DesiredState{} = desired_state) do
    with true <- Push.needed?(desired_state),
         {:ok, document} <- client.get(config, @clients_path),
         plan = Push.plan(desired_state, document),
         :ok <- apply_operations(config, plan.operations) do
      {:ok, %PushReport{provider: key(), operations: plan.operations, skipped: plan.skipped}}
    else
      false -> {:ok, %PushReport{provider: key(), operations: [], skipped: []}}
      error -> error
    end
  end

  defp apply_operations(config, operations) do
    Enum.reduce_while(operations, :ok, fn operation, :ok ->
      case config.client.request(config, :post, operation.path, operation.body) do
        {:ok, _body} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:failed, operation.summary, reason}}}
      end
    end)
  end

  defp client do
    :belgo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:client, Belgo.Providers.Adguard.HttpClient)
  end
end
