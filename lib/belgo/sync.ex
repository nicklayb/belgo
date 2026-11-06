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
end
