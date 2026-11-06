defmodule Belgo.Inventory.Types.IpAddress do
  @moduledoc "Ecto type for an IP address stored in its canonical string form."

  use Belgo.Inventory.Types.NormalizedString

  alias Belgo.Network.IpAddress

  @impl Belgo.Inventory.Types.NormalizedString
  def normalize(value) do
    with {:ok, address} <- IpAddress.parse(value), do: {:ok, IpAddress.format(address)}
  end
end
