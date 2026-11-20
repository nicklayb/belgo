defmodule Belgo.Discovery.Workloads do
  @moduledoc """
  Joins live workloads (pods, Docker containers, Proxmox guests) to the inventory.
  Pure functions only; nothing here is ever persisted.

  A workload's host is the inventory device named explicitly by the provider
  configuration, else the device holding one of the host's MAC addresses, else one
  of its IP addresses, else whose hostname, identifier or DNS name equals the host
  name (or its first label: `skynet.home.lan` matches `skynet`). Hosts matching no
  device are listed as unknown hosts.

  Proxmox guests are joined to inventory devices by MAC address. A guest running on
  another host than the device's `host_id` is a divergence, shown with the live
  placement (`LivePlacement`); the inventory is never changed automatically.
  """

  alias Belgo.Discovery.Correlation.Divergence
  alias Belgo.Discovery.Workload
  alias Belgo.Discovery.Workload.HostReference
  alias Belgo.Inventory.Codec
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Snapshot
  alias Belgo.Sync.DesiredState

  defmodule LivePlacement do
    @moduledoc """
    Where a provider sees a guest device running right now. `host_id` is the inventory
    device of that host (`nil` when unknown, `host_name` then tells what the provider
    calls it); `matches?` is `true` when it is the device's `host_id`.
    """
    @enforce_keys [:device_id, :provider, :host_name, :guest_name]
    defstruct [
      :device_id,
      :provider,
      :host_id,
      :host_name,
      :guest_name,
      :kind,
      :status,
      matches?: false
    ]

    @type t :: %__MODULE__{
            device_id: String.t(),
            provider: atom(),
            host_id: String.t() | nil,
            host_name: String.t(),
            guest_name: String.t(),
            kind: Workload.kind(),
            status: String.t() | nil,
            matches?: boolean()
          }
  end

  defmodule UnknownHost do
    @moduledoc "A host reported by a provider that no inventory device matches, with its workloads."
    @enforce_keys [:name, :provider, :workloads]
    defstruct [:name, :provider, :workloads]

    @type t :: %__MODULE__{name: String.t(), provider: atom(), workloads: [Workload.t()]}
  end

  defstruct by_host: %{}, unknown_hosts: [], placements: %{}, divergences: []

  @type t :: %__MODULE__{
          by_host: %{String.t() => [Workload.t()]},
          unknown_hosts: [UnknownHost.t()],
          placements: %{String.t() => LivePlacement.t()},
          divergences: [Divergence.t()]
        }

  @doc """
  Resolves the hosts (and, for guests, the devices) of `workloads` and computes the
  live placements of guest devices with their divergences.
  """
  @spec correlate(Snapshot.t(), [Workload.t()]) :: t()
  def correlate(%Snapshot{} = snapshot, workloads) do
    context = context(snapshot)
    resolved = Enum.map(workloads, &resolve(&1, context))
    {hosted, unhosted} = Enum.split_with(resolved, & &1.host_id)
    placements = placements(resolved, context)

    %__MODULE__{
      by_host:
        hosted
        |> Enum.group_by(& &1.host_id)
        |> Map.new(fn {host_id, host_workloads} -> {host_id, sort(host_workloads)} end),
      unknown_hosts: unknown_hosts(unhosted),
      placements: placements,
      divergences: divergences(placements, context)
    }
  end

  @doc "Lists the workloads of a kind running on a device, sorted by name."
  @spec on_host(t(), String.t(), Workload.kind() | [Workload.kind()]) :: [Workload.t()]
  def on_host(%__MODULE__{by_host: by_host}, device_id, kinds) do
    kinds = List.wrap(kinds)

    by_host
    |> Map.get(device_id, [])
    |> Enum.filter(&(&1.kind in kinds))
  end

  @doc "Returns where a guest device runs right now, when a provider reports it."
  @spec placement(t(), String.t()) :: LivePlacement.t() | nil
  def placement(%__MODULE__{placements: placements}, device_id),
    do: Map.get(placements, device_id)

  @doc """
  Params moving `device` onto the host of `placement` (`Belgo.Inventory.update/4`),
  keeping its other fields. The virtualisation follows the guest kind.
  """
  @spec host_params(Device.t(), LivePlacement.t()) :: map()
  def host_params(%Device{} = device, %LivePlacement{host_id: host_id} = placement)
      when is_binary(host_id) do
    Map.merge(Codec.encode(device), %{
      "placement" => "host",
      "host_id" => host_id,
      "virtualization" => Atom.to_string(placement.kind || device.virtualization)
    })
  end

  defp context(snapshot) do
    interfaces =
      for device <- snapshot.devices, interface <- device.interfaces, do: {device, interface}

    %{
      device_by_id: Snapshot.index(snapshot, :devices),
      device_by_mac:
        for({device, %{mac: mac}} <- interfaces, mac != nil, into: %{}, do: {mac, device}),
      device_by_ip:
        for({device, %{ip: ip}} <- interfaces, ip != nil, into: %{}, do: {ip, device}),
      device_by_name: device_by_name(snapshot)
    }
  end

  # Later entries win: DNS names first, then identifiers, then hostnames.
  defp device_by_name(snapshot) do
    device_by_id = Snapshot.index(snapshot, :devices)

    dns_names =
      for %{device_id: device_id, virtual_ip_id: nil} = record <-
            DesiredState.build(snapshot).dns_records,
          name <- [record.name, record.host],
          name != nil,
          do: {String.downcase(name), Map.fetch!(device_by_id, device_id)}

    identifiers =
      Enum.flat_map(snapshot.devices, fn device ->
        [{String.downcase(device.id), device}, {String.downcase(Device.hostname(device)), device}]
      end)

    Map.new(dns_names ++ identifiers)
  end

  defp resolve(%Workload{} = workload, context) do
    host = find_host(workload.host, context)
    device = if Workload.guest?(workload), do: find_by_macs(workload.macs, context)

    %Workload{workload | host_id: host && host.id, device_id: device && device.id}
  end

  defp find_host(%HostReference{device_id: device_id} = host, context) do
    Map.get(context.device_by_id, device_id) ||
      find_by_macs(host.macs, context) ||
      Enum.find_value(host.ips, &Map.get(context.device_by_ip, &1)) ||
      find_by_name(host.name, context)
  end

  defp find_by_macs(macs, context), do: Enum.find_value(macs, &Map.get(context.device_by_mac, &1))

  defp find_by_name(name, context) do
    name = String.downcase(name)
    [first_label | _domain] = String.split(name, ".")
    Map.get(context.device_by_name, name) || Map.get(context.device_by_name, first_label)
  end

  defp sort(workloads), do: Enum.sort_by(workloads, &{&1.kind, &1.name, &1.namespace || ""})

  defp unknown_hosts(workloads) do
    workloads
    |> Enum.group_by(&{&1.host.name, &1.provider})
    |> Enum.sort_by(fn {{name, provider}, _workloads} -> {name, provider} end)
    |> Enum.map(fn {{name, provider}, host_workloads} ->
      %UnknownHost{name: name, provider: provider, workloads: sort(host_workloads)}
    end)
  end

  defp placements(workloads, context) do
    for %Workload{device_id: device_id} = workload <- workloads,
        device_id != nil,
        into: %{} do
      device = Map.fetch!(context.device_by_id, device_id)

      {device_id,
       %LivePlacement{
         device_id: device_id,
         provider: workload.provider,
         host_id: workload.host_id,
         host_name: host_name(workload, context),
         guest_name: workload.name,
         kind: workload.kind,
         status: workload.status,
         matches?: workload.host_id != nil and workload.host_id == device.host_id
       }}
    end
  end

  defp host_name(%Workload{host_id: nil, host: host}, _context), do: host.name

  defp host_name(%Workload{host_id: host_id}, context),
    do: Map.fetch!(context.device_by_id, host_id).name

  defp divergences(placements, context) do
    placements
    |> Map.values()
    |> Enum.reject(& &1.matches?)
    |> Enum.sort_by(& &1.device_id)
    |> Enum.map(fn placement ->
      device = Map.fetch!(context.device_by_id, placement.device_id)

      %Divergence{
        collection: :devices,
        id: device.id,
        provider: placement.provider,
        message: divergence_message(placement, device, context)
      }
    end)
  end

  defp divergence_message(placement, device, context) do
    expected =
      case Map.get(context.device_by_id, device.host_id) do
        nil -> "no host"
        host -> host.name
      end

    running_on =
      if placement.host_id,
        do: placement.host_name,
        else: "#{placement.host_name} (unknown to Belgo)"

    "#{placement.guest_name} runs on #{running_on}, Belgo has #{expected}"
  end
end
