defmodule Belgo.Topology.Hosting do
  @moduledoc """
  The virtualisation tree: hosts (Proxmox nodes, Docker hosts...) and what runs on them.
  """

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Snapshot
  alias Belgo.Topology.DeviceNode
  alias Belgo.Topology.Physical

  @guest_kinds_by_platform %{
    proxmox: [:virtual_machine, :lxc],
    docker: [:container],
    kubernetes: [:container]
  }

  defmodule Host do
    @moduledoc """
    A host within one platform: the hosts it runs on (outermost first) and its direct
    guests of that platform.
    """
    @enforce_keys [:device]
    defstruct [:device, hosts: [], guests: []]

    @type t :: %__MODULE__{device: Device.t(), hosts: [Device.t()], guests: [Device.t()]}
  end

  defmodule Group do
    @moduledoc "The hosts of one platform (`nil`: hosts whose guests match none of their platforms)."
    @enforce_keys [:platform, :hosts]
    defstruct [:platform, :hosts]

    @type t :: %__MODULE__{platform: atom() | nil, hosts: [Host.t()]}
  end

  @doc """
  Builds the trees of the outermost hosts. A device is a host when it declares a
  platform or has guests.
  """
  @spec build(Snapshot.t()) :: [DeviceNode.t()]
  def build(%Snapshot{} = snapshot) do
    guests_by_host = DeviceNode.guests_by_host(snapshot)
    device_by_id = Snapshot.index(snapshot, :devices)

    snapshot.devices
    |> Enum.filter(&(outermost?(&1, device_by_id) and host?(&1, guests_by_host)))
    |> Enum.sort_by(&String.downcase(&1.name))
    |> Enum.map(&DeviceNode.build(&1, guests_by_host))
  end

  @doc """
  Groups hosts by platform (Proxmox, Docker, Kubernetes, in that order), each with its
  direct guests of that platform: VMs and LXC for Proxmox, containers for Docker and
  Kubernetes. A host declaring several platforms appears in each of them. Hosts with
  guests no platform accounts for (or without platform) form the last group, `nil`.
  Empty groups are omitted.
  """
  @spec groups(Snapshot.t()) :: [Group.t()]
  def groups(%Snapshot{} = snapshot) do
    guests_by_host = DeviceNode.guests_by_host(snapshot)

    hosts =
      snapshot.devices
      |> Enum.filter(&host?(&1, guests_by_host))
      |> Enum.sort_by(&String.downcase(&1.name))

    platform_groups =
      for platform <- Device.platforms(),
          members = platform_hosts(hosts, platform, guests_by_host, snapshot),
          members != [],
          do: %Group{platform: platform, hosts: members}

    case other_hosts(hosts, guests_by_host, snapshot) do
      [] -> platform_groups
      others -> platform_groups ++ [%Group{platform: nil, hosts: others}]
    end
  end

  defp platform_hosts(hosts, platform, guests_by_host, snapshot) do
    guest_kinds = Map.get(@guest_kinds_by_platform, platform, [])

    for device <- hosts, platform in device.platforms do
      host_entry(
        device,
        snapshot,
        guests_of(device, guests_by_host, &(&1.virtualization in guest_kinds))
      )
    end
  end

  defp other_hosts(hosts, guests_by_host, snapshot) do
    for device <- hosts,
        guests = guests_of(device, guests_by_host, &(not claimed?(device, &1))),
        device.platforms == [] or guests != [] do
      host_entry(device, snapshot, guests)
    end
  end

  defp claimed?(host, guest) do
    Enum.any?(host.platforms, fn platform ->
      guest.virtualization in Map.get(@guest_kinds_by_platform, platform, [])
    end)
  end

  defp guests_of(device, guests_by_host, filter) do
    guests_by_host
    |> Map.get(device.id, [])
    |> Enum.reject(&(&1.id == device.id))
    |> Enum.filter(filter)
  end

  defp host_entry(device, snapshot, guests) do
    %Host{device: device, hosts: Physical.device_path(snapshot, device).hosts, guests: guests}
  end

  defp host?(device, guests_by_host),
    do: Device.host?(device) or Map.has_key?(guests_by_host, device.id)

  defp outermost?(device, device_by_id),
    do: is_nil(device.host_id) or not Map.has_key?(device_by_id, device.host_id)
end
