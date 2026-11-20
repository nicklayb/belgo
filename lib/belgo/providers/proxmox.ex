defmodule Belgo.Providers.Proxmox do
  @moduledoc """
  Proxmox VE provider, read only: which node runs each VM and LXC container right
  now. Guests are joined to inventory devices by the MAC addresses of their
  configuration (names rarely equal hostnames); a guest running on another node than
  its device's host is a divergence, never reconciled automatically.

  Reads `/cluster/status` (node addresses), `/cluster/resources?type=vm` and each
  guest's `/nodes/{node}/{qemu|lxc}/{vmid}/config`.

  Options in `providers.yaml`:

    * `url` – any node of the cluster, e.g. `https://pve.home.lan:8006` (required)
    * `verify_tls` – verify the certificate, defaults to `true` (Proxmox uses a self
      signed certificate unless replaced)

  Secrets: `BELGO_PROXMOX_TOKEN_ID` (`user@realm!tokenid`, e.g. `belgo@pve!belgo`) and
  `BELGO_PROXMOX_TOKEN_SECRET` (or `*_FILE`), an API token with the `PVEAuditor` role on
  `/`.
  """

  @behaviour Belgo.Providers.Provider

  alias Belgo.Discovery.Report
  alias Belgo.Providers.Options
  alias Belgo.Providers.Proxmox.Translate
  alias Belgo.Providers.Secrets

  @option_names ~w(url verify_tls)
  @token_id_secret "BELGO_PROXMOX_TOKEN_ID"
  @token_secret_secret "BELGO_PROXMOX_TOKEN_SECRET"
  @status_path "/cluster/status"
  @resources_path "/cluster/resources?type=vm"
  @concurrent_config_reads 4
  @config_timeout_milliseconds 20_000

  defmodule Config do
    @moduledoc "Connection settings of a Proxmox VE cluster."
    @enforce_keys [:url, :token_id, :token_secret]
    defstruct [
      :url,
      :token_id,
      :token_secret,
      verify_tls: true,
      client: Belgo.Providers.Proxmox.HttpClient
    ]

    @type t :: %__MODULE__{
            url: String.t(),
            token_id: String.t(),
            token_secret: String.t(),
            verify_tls: boolean(),
            client: module()
          }
  end

  defimpl Inspect, for: Config do
    def inspect(config, _options), do: "#Belgo.Providers.Proxmox.Config<url: #{config.url}>"
  end

  @impl Belgo.Providers.Provider
  def key, do: :proxmox

  @impl Belgo.Providers.Provider
  def label, do: "Proxmox VE"

  @impl Belgo.Providers.Provider
  def parse_config(options, environment) do
    Options.build(Config,
      options: Options.validate_names(options, @option_names),
      url: Options.url(options["url"]),
      verify_tls: Options.boolean(Map.get(options, "verify_tls", true), "verify_tls"),
      token_id: Secrets.fetch(@token_id_secret, environment),
      token_secret: Secrets.fetch(@token_secret_secret, environment),
      client: {:ok, client()}
    )
  end

  @doc """
  Reads the guests. The node addresses and guest configurations are best effort: a
  failure is reported in `Report.failures` (guests then lack addresses or MACs); only
  the guest list itself failing fails the pull.
  """
  @impl Belgo.Providers.Provider
  def discover(%Config{client: client} = config) do
    with {:ok, rows} <- client.get(config, @resources_path) do
      {ip_by_node, node_failures} = node_addresses(config)
      {workloads, config_failures} = read_guests(config, Translate.guests(rows), ip_by_node)
      {:ok, Report.with_workloads(key(), workloads, node_failures ++ config_failures)}
    end
  end

  defp node_addresses(%Config{client: client} = config) do
    case client.get(config, @status_path) do
      {:ok, rows} when is_list(rows) -> {Translate.node_addresses(rows), []}
      {:ok, other} -> {%{}, [nodes: {:unexpected_body, @status_path, other}]}
      {:error, reason} -> {%{}, [nodes: reason]}
    end
  end

  defp read_guests(config, guests, ip_by_node) do
    results =
      guests
      |> Task.async_stream(&read_macs(config, &1),
        max_concurrency: @concurrent_config_reads,
        timeout: @config_timeout_milliseconds,
        on_timeout: :kill_task
      )
      |> Enum.zip(guests)
      |> Enum.map(fn
        {{:ok, result}, _guest} -> result
        {{:exit, reason}, guest} -> {:error, Translate.config_path(guest), reason}
      end)

    workloads =
      guests
      |> Enum.zip(results)
      |> Enum.map(fn
        {guest, {:ok, macs}} -> Translate.workload(guest, macs, ip_by_node)
        {guest, {:error, _path, _reason}} -> Translate.workload(guest, [], ip_by_node)
      end)

    failures = for {:error, path, reason} <- results, do: {:config, {path, reason}}
    {workloads, failures}
  end

  defp read_macs(%Config{client: client} = config, guest) do
    path = Translate.config_path(guest)

    case client.get(config, path) do
      {:ok, guest_config} -> {:ok, Translate.mac_addresses(guest_config)}
      {:error, reason} -> {:error, path, reason}
    end
  end

  defp client do
    :belgo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:client, Belgo.Providers.Proxmox.HttpClient)
  end
end
