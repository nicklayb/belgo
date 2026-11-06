defmodule Belgo.Topology.DeviceNode do
  @moduledoc "A device with the guests (VMs, containers...) it hosts, recursively."

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Snapshot

  defstruct [:device, guests: []]

  @type t :: %__MODULE__{device: Device.t(), guests: [t()]}
  @type guests_by_host :: %{String.t() => [Device.t()]}

  @doc "Groups the devices of a snapshot by the identifier of their host, sorted by name."
  @spec guests_by_host(Snapshot.t()) :: guests_by_host()
  def guests_by_host(%Snapshot{devices: devices}) do
    devices
    |> Enum.filter(& &1.host_id)
    |> Enum.sort_by(&String.downcase(&1.name))
    |> Enum.group_by(& &1.host_id)
  end

  @doc "Builds the node of a device. Cycles are cut so the tree is always finite."
  @spec build(Device.t(), guests_by_host()) :: t()
  def build(%Device{} = device, guests_by_host), do: build(device, guests_by_host, MapSet.new())

  defp build(device, guests_by_host, visited) do
    visited = MapSet.put(visited, device.id)

    guests =
      guests_by_host
      |> Map.get(device.id, [])
      |> Enum.reject(&MapSet.member?(visited, &1.id))
      |> Enum.map(&build(&1, guests_by_host, visited))

    %__MODULE__{device: device, guests: guests}
  end

  @doc "Lists the identifiers of every device in the nodes, guests included."
  @spec device_ids([t()]) :: [String.t()]
  def device_ids(nodes) do
    Enum.flat_map(nodes, fn node -> [node.device.id | device_ids(node.guests)] end)
  end

  @doc "Counts the devices of a node, itself included."
  @spec count(t()) :: pos_integer()
  def count(%__MODULE__{guests: guests}), do: 1 + Enum.sum_by(guests, &count/1)
end
