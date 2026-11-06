defmodule Belgo.Discovery.Matching do
  @moduledoc """
  Fuzzy matching of a discovered device against the inventory, to pre-select the
  device a discovery probably belongs to (`skynet-wifi` → Skynet). Pure functions.
  """

  alias Belgo.Discovery.Correlation.DiscoveredDevice
  alias Belgo.Inventory.Device

  @minimum_score 0.8
  @separators ~r/[^a-z0-9]+/

  @doc """
  Returns the inventory device whose name or hostname is the closest to the names of
  the discovered device, with its score (0 to 1), or `nil` below #{@minimum_score}.
  """
  @spec best_device(DiscoveredDevice.t(), [Device.t()]) :: {Device.t(), float()} | nil
  def best_device(%DiscoveredDevice{} = discovered, devices) do
    names = discovered_names(discovered)

    devices
    |> Enum.map(&{&1, score(names, &1)})
    |> Enum.filter(fn {_device, score} -> score >= @minimum_score end)
    |> Enum.max_by(fn {_device, score} -> score end, fn -> nil end)
  end

  defp discovered_names(discovered) do
    [
      discovered.hostname,
      discovered.description | Enum.map(discovered.observations, & &1.hostname)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp score([], _device), do: 0.0

  defp score(names, device) do
    device_names =
      [device.name, Device.hostname(device), device.id]
      |> Enum.map(&normalize/1)
      |> Enum.uniq()

    for name <- names, device_name <- device_names, reduce: 0.0 do
      best -> max(best, String.jaro_distance(name, device_name))
    end
  end

  defp normalize(name) do
    name
    |> String.downcase()
    |> String.replace(@separators, " ")
    |> String.trim()
  end
end
