defmodule Belgo.Discovery.UseCase.StopIgnoringDevice do
  @moduledoc """
  Removes the MAC addresses of a discovered device from the denylist so it is
  suggested again. Params are the `DiscoveredDevice`.
  """

  use Belgo.UseCase

  alias Belgo.Discovery.Correlation.DiscoveredDevice
  alias Belgo.Inventory.Transaction

  @impl Box.UseCase
  def validate(%DiscoveredDevice{} = discovered, options) do
    with {:ok, _user} <- authorize(options), do: {:ok, discovered}
  end

  @impl Box.UseCase
  def run(multi, %DiscoveredDevice{} = discovered, _options) do
    Enum.reduce(discovered.macs, multi, fn mac, accumulator ->
      Transaction.delete_existing(accumulator, {:allowed, mac}, :denylist, mac)
    end)
  end

  @impl Box.UseCase
  def return(changes, _options),
    do:
      changes
      |> Map.values()
      |> Enum.reject(&is_nil/1)
end
