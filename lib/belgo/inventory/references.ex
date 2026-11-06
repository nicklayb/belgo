defmodule Belgo.Inventory.References do
  @moduledoc "Finds records pointing at a given record, to prevent breaking deletions."

  alias Belgo.Inventory.Snapshot

  @type referrer :: {Snapshot.collection(), String.t(), String.t()}

  @doc "Lists `{collection, id, name}` of records referencing the given record."
  @spec list(Snapshot.t(), Snapshot.collection(), String.t()) :: [referrer()]
  def list(%Snapshot{} = snapshot, :locations, id) do
    child_locations = Enum.filter(snapshot.locations, &(&1.parent_id == id))
    located_devices = Enum.filter(snapshot.devices, &(&1.location_id == id))

    describe(:locations, child_locations) ++ describe(:devices, located_devices)
  end

  def list(%Snapshot{} = snapshot, :networks, id) do
    devices =
      Enum.filter(snapshot.devices, fn device ->
        Enum.any?(device.interfaces, &(&1.network_id == id))
      end)

    describe(:devices, devices) ++
      describe(:virtual_ips, Enum.filter(snapshot.virtual_ips, &(&1.network_id == id)))
  end

  def list(%Snapshot{} = snapshot, :devices, id) do
    devices =
      Enum.filter(snapshot.devices, fn device ->
        device.id != id and
          (device.host_id == id or device.uplink_id == id or
             Enum.any?(device.interfaces, &(&1.switch_id == id)))
      end)

    describe(:devices, devices) ++
      describe(:virtual_ips, Enum.filter(snapshot.virtual_ips, &(&1.owner_id == id)))
  end

  def list(%Snapshot{}, :virtual_ips, _id), do: []
  # Plans refer to devices and locations, nothing refers to a plan.
  def list(%Snapshot{}, :plans, _id), do: []
  def list(%Snapshot{}, :denylist, _id), do: []

  defp describe(collection, records) do
    Enum.map(records, &{collection, &1.id, &1.name})
  end
end
