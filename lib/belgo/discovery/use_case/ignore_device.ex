defmodule Belgo.Discovery.UseCase.IgnoreDevice do
  @moduledoc """
  Adds every MAC address of a discovered device to the denylist so it is no longer
  suggested. Params are the `DiscoveredDevice`; returns the denylist entries.
  """

  use Belgo.UseCase

  alias Belgo.Discovery.Correlation.DiscoveredDevice
  alias Belgo.Inventory.Transaction

  @impl Box.UseCase
  def validate(%DiscoveredDevice{macs: []}, _options), do: {:error, :no_mac_address}

  def validate(%DiscoveredDevice{} = discovered, options) do
    with {:ok, _user} <- authorize(options), do: {:ok, discovered}
  end

  @impl Box.UseCase
  def run(multi, %DiscoveredDevice{} = discovered, _options) do
    Enum.reduce(discovered.macs, multi, fn mac, accumulator ->
      params = %{"name" => discovered.hostname || discovered.description}
      Transaction.put_missing(accumulator, {:denied, mac}, :denylist, {mac, params})
    end)
  end

  @impl Box.UseCase
  def return(changes, _options), do: Map.values(changes)
end
