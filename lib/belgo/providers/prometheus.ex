defmodule Belgo.Providers.Prometheus do
  @moduledoc """
  Prometheus provider, read only: what runs on the hosts right now, from metrics
  already scraped (nothing is installed on the hosts).

    * Kubernetes pods per node, from kube-state-metrics
    * Docker containers per host, from cAdvisor

  Queried directly (`url` of Prometheus) or through Grafana's data source proxy
  (`url` of Grafana and `datasource_uid`, authenticated with a service account
  token), which suits a Prometheus only reachable inside its Docker network.

  Options in `providers.yaml`:

    * `url` – Prometheus or Grafana base URL (required)
    * `datasource_uid` – the Prometheus data source in Grafana (queries go through
      Grafana when set)
    * `verify_tls` – verify the certificate, defaults to `true`
    * `namespaces` – Kubernetes namespaces whose pods are followed, all when absent
    * `instances` – inventory device of cAdvisor scrape targets whose host name is
      not one of the device's names, e.g. `{"cadvisor:8080": monitor}`

  Secret (optional): `BELGO_PROMETHEUS_TOKEN` (or `BELGO_PROMETHEUS_TOKEN_FILE`), sent
  as a bearer token: a Grafana service account token (role Viewer) through Grafana.
  """

  @behaviour Belgo.Providers.Provider

  alias Belgo.Discovery.Report
  alias Belgo.Providers.Options
  alias Belgo.Providers.Prometheus.Translate
  alias Belgo.Providers.Secrets

  @option_names ~w(url datasource_uid verify_tls namespaces instances)
  @token_secret "BELGO_PROMETHEUS_TOKEN"
  @namespace_format ~r/\A[a-z0-9]([-a-z0-9]*[a-z0-9])?\z/

  defmodule Config do
    @moduledoc "Connection settings of a Prometheus server (or of Grafana in front of it)."
    @enforce_keys [:url]
    defstruct [
      :url,
      :datasource_uid,
      :token,
      :namespaces,
      verify_tls: true,
      instances: %{},
      client: Belgo.Providers.Prometheus.HttpClient
    ]

    @type t :: %__MODULE__{
            url: String.t(),
            datasource_uid: String.t() | nil,
            token: String.t() | nil,
            namespaces: [String.t()] | nil,
            verify_tls: boolean(),
            instances: %{String.t() => String.t()},
            client: module()
          }
  end

  defimpl Inspect, for: Config do
    def inspect(config, _options),
      do: "#Belgo.Providers.Prometheus.Config<url: #{config.url}>"
  end

  @impl Belgo.Providers.Provider
  def key, do: :prometheus

  @impl Belgo.Providers.Provider
  def label, do: "Prometheus"

  @impl Belgo.Providers.Provider
  def parse_config(options, environment) do
    Options.build(Config,
      options: Options.validate_names(options, @option_names),
      url: Options.url(options["url"]),
      datasource_uid: optional_string(options["datasource_uid"], "datasource_uid"),
      verify_tls: Options.boolean(Map.get(options, "verify_tls", true), "verify_tls"),
      namespaces: namespaces(options["namespaces"]),
      instances: instances(Map.get(options, "instances", %{})),
      token: Secrets.fetch_optional(@token_secret, environment),
      client: {:ok, client()}
    )
  end

  @impl Belgo.Providers.Provider
  def discover(%Config{} = config) do
    results = [pods: pods(config), containers: containers(config)]
    failures = for {part, {:error, reason}} <- results, do: {part, reason}

    case failures do
      [_pods, _containers] ->
        {:error, failures}

      _partial_or_none ->
        workloads = for {_part, {:ok, workloads}} <- results, workload <- workloads, do: workload
        {:ok, Report.with_workloads(key(), workloads, failures)}
    end
  end

  defp pods(%Config{} = config) do
    with {:ok, samples} <- query_all(config, Translate.pod_queries(config.namespaces)) do
      {:ok, Translate.pods(samples)}
    end
  end

  # Runs every named query, stopping at the first failure (`{:error, {name, reason}}`).
  defp query_all(%Config{client: client} = config, promql_by_name) do
    Enum.reduce_while(promql_by_name, {:ok, %{}}, fn {name, promql}, {:ok, samples} ->
      case client.query(config, promql) do
        {:ok, result} -> {:cont, {:ok, Map.put(samples, name, result)}}
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
  end

  defp containers(%Config{client: client} = config) do
    with {:ok, samples} <- client.query(config, Translate.container_query()) do
      {:ok, Translate.containers(samples, config.instances)}
    end
  end

  defp optional_string(nil, _name), do: {:ok, nil}
  defp optional_string(value, _name) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_string(_value, name), do: {:error, "#{name} must be a non-empty string"}

  defp namespaces(nil), do: {:ok, nil}

  defp namespaces(values) when is_list(values) do
    if values != [] and
         Enum.all?(values, &(is_binary(&1) and Regex.match?(@namespace_format, &1))),
       do: {:ok, Enum.uniq(values)},
       else: {:error, "namespaces must be a list of Kubernetes namespace names"}
  end

  defp namespaces(_value), do: {:error, "namespaces must be a list of Kubernetes namespace names"}

  defp instances(values) when is_map(values) do
    if Enum.all?(values, fn {instance, device_id} ->
         is_binary(instance) and is_binary(device_id) and device_id != ""
       end),
       do: {:ok, values},
       else: {:error, "instances must map scrape targets to device identifiers"}
  end

  defp instances(_value), do: {:error, "instances must map scrape targets to device identifiers"}

  defp client do
    :belgo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:client, Belgo.Providers.Prometheus.HttpClient)
  end
end
