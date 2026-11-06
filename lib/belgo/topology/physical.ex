defmodule Belgo.Topology.Physical do
  @moduledoc """
  The physical map of the homelab: the location tree with the devices it contains.

  Guests appear under their host, so a VM is shown where its hypervisor is.
  Devices that cannot be placed (unknown references, cycles) end up in `unplaced`
  so nothing is ever hidden.
  """

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Location
  alias Belgo.Inventory.Snapshot
  alias Belgo.Topology.DeviceNode

  defmodule LocationNode do
    @moduledoc "A location with its sub-locations and the devices placed directly in it."

    defstruct [:location, locations: [], devices: []]

    @type t :: %__MODULE__{
            location: Location.t(),
            locations: [t()],
            devices: [DeviceNode.t()]
          }
  end

  defmodule DevicePlacement do
    @moduledoc """
    A device found inside a location: the sub-locations between that location and the
    device, and the hosts it runs on (outermost first).
    """

    @enforce_keys [:device]
    defstruct [:device, locations: [], hosts: []]

    @type t :: %__MODULE__{device: Device.t(), locations: [Location.t()], hosts: [Device.t()]}
  end

  defstruct roots: [], portable: [], unplaced: []

  @type t :: %__MODULE__{
          roots: [LocationNode.t()],
          portable: [DeviceNode.t()],
          unplaced: [DeviceNode.t()]
        }

  @doc "Builds the physical map."
  @spec build(Snapshot.t()) :: t()
  def build(%Snapshot{} = snapshot) do
    guests_by_host = DeviceNode.guests_by_host(snapshot)
    devices = Enum.sort_by(snapshot.devices, &String.downcase(&1.name))
    devices_by_location = Enum.group_by(devices, & &1.location_id)

    children_by_parent =
      snapshot.locations
      |> sort_locations()
      |> Enum.group_by(& &1.parent_id)

    roots =
      snapshot
      |> root_locations()
      |> Enum.map(
        &location_node(&1, children_by_parent, devices_by_location, guests_by_host, MapSet.new())
      )

    portable =
      devices
      |> Enum.filter(&(Device.placement(&1) == :portable))
      |> Enum.map(&DeviceNode.build(&1, guests_by_host))

    placed_ids = MapSet.new(DeviceNode.device_ids(portable) ++ location_device_ids(roots))

    unplaced =
      devices
      |> Enum.reject(&MapSet.member?(placed_ids, &1.id))
      |> unplaced_roots(guests_by_host)

    %__MODULE__{roots: roots, portable: portable, unplaced: unplaced}
  end

  @doc "Returns the locations from the root down to the given location."
  @spec path(Snapshot.t(), String.t() | nil) :: [Location.t()]
  def path(%Snapshot{} = snapshot, location_id) do
    location_by_id = Snapshot.index(snapshot, :locations)
    walk_up(location_id, location_by_id, [], MapSet.new())
  end

  @doc """
  Returns where a device physically is: the location path and the chain of hosts
  (outermost first) leading to it.
  """
  @spec device_path(Snapshot.t(), Device.t()) :: %{locations: [Location.t()], hosts: [Device.t()]}
  def device_path(%Snapshot{} = snapshot, %Device{} = device) do
    device_by_id = Snapshot.index(snapshot, :devices)
    hosts = host_chain(device, device_by_id, [], MapSet.new([device.id]))
    outermost = List.first(hosts, device)

    %{locations: path(snapshot, outermost.location_id), hosts: hosts}
  end

  @doc """
  Lists every device inside a location, its sub-locations included, guests following
  their host. Sorted by sub-location path, then by name.
  """
  @spec devices_within(Snapshot.t(), String.t()) :: [DevicePlacement.t()]
  def devices_within(%Snapshot{} = snapshot, location_id) do
    snapshot.devices
    |> Enum.flat_map(fn device ->
      %{locations: locations, hosts: hosts} = device_path(snapshot, device)

      case Enum.split_while(locations, &(&1.id != location_id)) do
        {_above, [_location | below]} ->
          [%DevicePlacement{device: device, locations: below, hosts: hosts}]

        {_above, []} ->
          []
      end
    end)
    |> Enum.sort_by(fn placement ->
      {Enum.map(placement.locations, &String.downcase(&1.name)),
       String.downcase(placement.device.name)}
    end)
  end

  @doc "Lists the locations directly inside a location, sorted by name."
  @spec children(Snapshot.t(), String.t()) :: [Location.t()]
  def children(%Snapshot{} = snapshot, location_id) do
    snapshot.locations
    |> Enum.filter(&(&1.parent_id == location_id and &1.id != location_id))
    |> sort_locations()
  end

  @doc "Lists locations as `{label, id}` options, labelled with their full path."
  @spec location_options(Snapshot.t()) :: [{String.t(), String.t()}]
  def location_options(%Snapshot{} = snapshot) do
    snapshot.locations
    |> Enum.map(fn location ->
      label =
        snapshot
        |> path(location.id)
        |> Enum.map_join(" / ", & &1.name)

      {label, location.id}
    end)
    |> Enum.sort_by(fn {label, _id} -> String.downcase(label) end)
  end

  defp root_locations(snapshot) do
    location_by_id = Snapshot.index(snapshot, :locations)

    snapshot.locations
    |> Enum.filter(fn location ->
      is_nil(location.parent_id) or not Map.has_key?(location_by_id, location.parent_id) or
        cyclic_location?(location, location_by_id)
    end)
    |> sort_locations()
  end

  defp cyclic_location?(location, location_by_id) do
    location.id in Enum.map(
      walk_up(location.parent_id, location_by_id, [], MapSet.new()),
      & &1.id
    )
  end

  defp location_node(location, children_by_parent, devices_by_location, guests_by_host, visited) do
    visited = MapSet.put(visited, location.id)

    %LocationNode{
      location: location,
      locations:
        children_by_parent
        |> Map.get(location.id, [])
        |> Enum.reject(&MapSet.member?(visited, &1.id))
        |> Enum.map(
          &location_node(&1, children_by_parent, devices_by_location, guests_by_host, visited)
        ),
      devices:
        devices_by_location
        |> Map.get(location.id, [])
        |> Enum.filter(&match?({:location, _id}, Device.placement(&1)))
        |> Enum.map(&DeviceNode.build(&1, guests_by_host))
    }
  end

  defp location_device_ids(location_nodes) do
    Enum.flat_map(location_nodes, fn node ->
      DeviceNode.device_ids(node.devices) ++ location_device_ids(node.locations)
    end)
  end

  defp unplaced_roots(devices, guests_by_host) do
    unplaced_ids = MapSet.new(devices, & &1.id)

    devices
    |> Enum.reject(
      &(&1.host_id && MapSet.member?(unplaced_ids, &1.host_id) && &1.host_id != &1.id)
    )
    |> Enum.map(&DeviceNode.build(&1, guests_by_host))
    |> then(fn nodes -> nodes ++ cyclic_leftovers(devices, nodes, guests_by_host) end)
  end

  defp cyclic_leftovers(devices, nodes, guests_by_host) do
    reached_ids = MapSet.new(DeviceNode.device_ids(nodes))

    devices
    |> Enum.reject(&MapSet.member?(reached_ids, &1.id))
    |> Enum.map(&%DeviceNode{DeviceNode.build(&1, guests_by_host) | guests: []})
  end

  defp walk_up(nil, _location_by_id, path, _visited), do: path

  defp walk_up(location_id, location_by_id, path, visited) do
    with false <- MapSet.member?(visited, location_id),
         {:ok, location} <- Map.fetch(location_by_id, location_id) do
      walk_up(
        location.parent_id,
        location_by_id,
        [location | path],
        MapSet.put(visited, location_id)
      )
    else
      _ -> path
    end
  end

  defp host_chain(%Device{host_id: nil}, _device_by_id, chain, _visited), do: chain

  defp host_chain(%Device{host_id: host_id}, device_by_id, chain, visited) do
    with false <- MapSet.member?(visited, host_id),
         {:ok, host} <- Map.fetch(device_by_id, host_id) do
      host_chain(host, device_by_id, [host | chain], MapSet.put(visited, host_id))
    else
      _ -> chain
    end
  end

  defp sort_locations(locations), do: Enum.sort_by(locations, &String.downcase(&1.name))
end
