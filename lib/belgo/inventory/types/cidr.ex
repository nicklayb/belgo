defmodule Belgo.Inventory.Types.Cidr do
  @moduledoc "Ecto type for a CIDR range stored with its host bits cleared."

  use Belgo.Inventory.Types.NormalizedString

  alias Belgo.Network.Cidr

  @impl Belgo.Inventory.Types.NormalizedString
  def normalize(value) do
    with {:ok, cidr} <- Cidr.parse(value), do: {:ok, Cidr.format(cidr)}
  end
end
