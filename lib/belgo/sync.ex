defmodule Belgo.Sync do
  @moduledoc "Side effects of inventory changes on the external systems."

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.VirtualIp

  @doc "Pushes a saved device or virtual IP to the providers; other records are not pushed."
  @spec after_save(Snapshot.collection(), Snapshot.entity()) :: :ok
  def after_save(:devices, %Device{id: id}), do: Belgo.Discovery.push_device(id)
  def after_save(:virtual_ips, %VirtualIp{id: id}), do: Belgo.Discovery.push_virtual_ip(id)
  def after_save(_collection, _record), do: :ok

  @doc """
  Pushes an updated record like `after_save/2`, and deletes the provider entries of
  the MAC addresses the update removed from a device (Kea reservations).
  """
  @spec after_update(Snapshot.collection(), Snapshot.entity(), Snapshot.entity()) :: :ok
  def after_update(:devices, %Device{} = previous, %Device{} = device) do
    release(previous, device)
    after_save(:devices, device)
  end

  def after_update(collection, _previous, record), do: after_save(collection, record)

  @doc "Deletes the provider entries of a deleted device's MAC addresses (Kea reservations)."
  @spec after_delete(Snapshot.collection(), Snapshot.entity()) :: :ok
  def after_delete(:devices, %Device{} = device), do: release(device, nil)
  def after_delete(_collection, _record), do: :ok

  defp release(%Device{id: id} = previous, current) do
    Belgo.Discovery.release_mac_addresses(
      {:devices, id},
      Device.released_mac_addresses(previous, current)
    )
  end
end
