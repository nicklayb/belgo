defmodule Belgo.Providers.Opnsense do
  @moduledoc """
  OPNsense provider: Kea DHCPv4 subnets (networks) and reservations (devices), and
  Unbound host overrides (DNS names). Pushes write reservations and host overrides,
  then reconfigure the touched services. Releases delete the Kea reservations of MAC
  addresses removed from the inventory.

  Kea and Unbound are independent: one failing (missing privileges, service not
  used...) is reported without blocking the other, and a push only reads the
  services it has something to write to.

  Options in `providers.yaml`:

    * `url` – base URL of the web UI, e.g. `https://opnsense.home.lan` (required)
    * `verify_tls` – verify the certificate, defaults to `true`

  Secrets: `BELGO_OPNSENSE_API_KEY` and `BELGO_OPNSENSE_API_SECRET` (or `*_FILE`).
  """

  @behaviour Belgo.Providers.Provider

  alias Belgo.Discovery.Report
  alias Belgo.Providers.Opnsense.Push
  alias Belgo.Providers.Opnsense.Translate
  alias Belgo.Providers.Options
  alias Belgo.Providers.Secrets
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.PushReport

  @option_names ~w(url verify_tls)
  @api_key_secret "BELGO_OPNSENSE_API_KEY"
  @api_secret_secret "BELGO_OPNSENSE_API_SECRET"
  @subnets_path "/api/kea/dhcpv4/search_subnet"
  @reservations_path "/api/kea/dhcpv4/search_reservation"
  @host_overrides_path "/api/unbound/settings/search_host_override"
  # `deleted` answers a deletion, `not found` one of an entry already gone.
  @successful_results ["saved", "deleted", "not found"]
  @reconfigure_paths %{
    kea: "/api/kea/service/reconfigure",
    unbound: "/api/unbound/service/reconfigure"
  }

  defmodule Config do
    @moduledoc "Connection settings of an OPNsense instance."
    @enforce_keys [:url, :api_key, :api_secret]
    defstruct [
      :url,
      :api_key,
      :api_secret,
      verify_tls: true,
      client: Belgo.Providers.Opnsense.HttpClient
    ]

    @type t :: %__MODULE__{
            url: String.t(),
            api_key: String.t(),
            api_secret: String.t(),
            verify_tls: boolean(),
            client: module()
          }
  end

  defimpl Inspect, for: Config do
    def inspect(config, _options), do: "#Belgo.Providers.Opnsense.Config<url: #{config.url}>"
  end

  @impl Belgo.Providers.Provider
  def key, do: :opnsense

  @impl Belgo.Providers.Provider
  def label, do: "OPNsense"

  @impl Belgo.Providers.Provider
  def parse_config(options, environment) do
    Options.build(Config,
      options: Options.validate_names(options, @option_names),
      url: Options.url(options["url"]),
      verify_tls: Options.boolean(Map.get(options, "verify_tls", true), "verify_tls"),
      api_key: Secrets.fetch(@api_key_secret, environment),
      api_secret: Secrets.fetch(@api_secret_secret, environment),
      client: {:ok, client()}
    )
  end

  @impl Belgo.Providers.Provider
  def discover(%Config{} = config) do
    results = [kea: discover_kea(config), unbound: discover_unbound(config)]
    failures = for {service, {:error, reason}} <- results, do: {service, reason}

    case failures do
      [_kea, _unbound] ->
        {:error, failures}

      _partial_or_none ->
        observations = Enum.flat_map(results, fn {_service, result} -> observations(result) end)
        {:ok, Report.new(key(), observations, failures)}
    end
  end

  defp discover_kea(%Config{client: client} = config) do
    with {:ok, subnet_rows} <- client.search(config, @subnets_path),
         {:ok, reservation_rows} <- client.search(config, @reservations_path) do
      {:ok,
       Translate.subnets(subnet_rows) ++
         Translate.gateway(subnet_rows) ++
         Translate.reservations(reservation_rows, subnet_rows)}
    end
  end

  defp discover_unbound(%Config{client: client} = config) do
    with {:ok, host_override_rows} <- client.search(config, @host_overrides_path) do
      {:ok, Translate.host_overrides(host_override_rows)}
    end
  end

  defp observations({:ok, observations}), do: observations
  defp observations({:error, _reason}), do: []

  @impl Belgo.Providers.Provider
  def push(%Config{} = config, %DesiredState{} = desired_state) do
    results =
      Enum.flat_map(
        [kea: Push.kea_needed?(desired_state), unbound: Push.unbound_needed?(desired_state)],
        fn
          {service, true} -> [{service, push_service(config, service, desired_state)}]
          {_service, false} -> []
        end
      )

    failures = for {service, {:error, reason}} <- results, do: {service, reason}
    plans = for {_service, {:ok, plan}} <- results, do: plan

    if results != [] and plans == [] do
      {:error, failures}
    else
      {:ok,
       %PushReport{
         provider: key(),
         operations: Enum.flat_map(plans, & &1.operations),
         skipped: Enum.flat_map(plans, & &1.skipped),
         failures: failures
       }}
    end
  end

  @impl Belgo.Providers.Provider
  def release(%Config{client: client} = config, mac_addresses) do
    with {:ok, reservation_rows} <- client.search(config, @reservations_path),
         plan = Push.plan_kea_release(mac_addresses, %{reservations: reservation_rows}),
         {:ok, plan} <- apply_plan(config, :kea, plan) do
      {:ok, %PushReport{provider: key(), operations: plan.operations, skipped: plan.skipped}}
    end
  end

  defp push_service(config, service, desired_state) do
    with {:ok, plan} <- plan_service(config, service, desired_state) do
      apply_plan(config, service, plan)
    end
  end

  defp plan_service(%Config{client: client} = config, :kea, desired_state) do
    with {:ok, subnet_rows} <- client.search(config, @subnets_path),
         {:ok, reservation_rows} <- client.search(config, @reservations_path) do
      {:ok, Push.plan_kea(desired_state, %{subnets: subnet_rows, reservations: reservation_rows})}
    end
  end

  defp plan_service(%Config{client: client} = config, :unbound, desired_state) do
    with {:ok, host_override_rows} <- client.search(config, @host_overrides_path) do
      {:ok, Push.plan_unbound(desired_state, %{host_overrides: host_override_rows})}
    end
  end

  defp apply_plan(_config, _service, %{operations: []} = plan), do: {:ok, plan}

  defp apply_plan(config, service, plan) do
    result = Enum.reduce_while(plan.operations, :ok, &apply_operation(config, &1, &2))
    reconfigured = reconfigure(config, service)

    with :ok <- result,
         :ok <- reconfigured do
      {:ok, plan}
    end
  end

  defp apply_operation(config, operation, :ok) do
    case config.client.post(config, operation.path, operation.body) do
      {:ok, %{"result" => result}} when result in @successful_results -> {:cont, :ok}
      {:ok, response} -> {:halt, {:error, {:rejected, operation.summary, response}}}
      {:error, reason} -> {:halt, {:error, {:failed, operation.summary, reason}}}
    end
  end

  defp reconfigure(config, service) do
    case config.client.post(config, Map.fetch!(@reconfigure_paths, service), %{}) do
      {:ok, %{"status" => "ok"}} -> :ok
      {:ok, response} -> {:error, {:reconfigure_failed, response}}
      {:error, reason} -> {:error, {:reconfigure_failed, reason}}
    end
  end

  defp client do
    :belgo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:client, Belgo.Providers.Opnsense.HttpClient)
  end
end
