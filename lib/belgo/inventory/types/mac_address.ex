defmodule Belgo.Inventory.Types.MacAddress do
  @moduledoc "Ecto type for a MAC address stored lowercase and colon separated."

  use Belgo.Inventory.Types.NormalizedString

  @impl Belgo.Inventory.Types.NormalizedString
  defdelegate normalize(value), to: Belgo.Network.MacAddress
end
