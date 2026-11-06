defmodule Belgo.Discovery.Sorting do
  @moduledoc """
  Sorts discovered devices for display, by `:device` (name, case insensitive, nameless
  last) or by `:address` (first IP numerically, then first MAC; none last). Pure.
  """

  alias Belgo.Discovery.Correlation.DiscoveredDevice
  alias Belgo.Network.IpAddress

  @fields [:device, :address]
  @directions [:asc, :desc]

  @type field :: :device | :address
  @type direction :: :asc | :desc

  @doc "Parses a field name, `nil` when unknown."
  @spec parse_field(String.t()) :: field() | nil
  def parse_field(name), do: Enum.find(@fields, &(Atom.to_string(&1) == name))

  @doc "Sorts devices; entries without the sorted value stay last in both directions."
  @spec sort([DiscoveredDevice.t()], field(), direction()) :: [DiscoveredDevice.t()]
  def sort(devices, field, direction) when field in @fields and direction in @directions do
    {valued, missing} = Enum.split_with(devices, &(sort_key(&1, field) != nil))

    Enum.sort_by(valued, &{sort_key(&1, field), &1.id}, direction) ++
      Enum.sort_by(missing, & &1.id)
  end

  @doc "Direction after clicking `field`: toggled when already sorted by it, else ascending."
  @spec next({field(), direction()}, field()) :: {field(), direction()}
  def next({field, :asc}, field), do: {field, :desc}
  def next({field, :desc}, field), do: {field, :asc}
  def next(_current, field), do: {field, :asc}

  defp sort_key(%DiscoveredDevice{} = device, :device) do
    case device.hostname || device.description do
      nil -> nil
      name -> String.downcase(name)
    end
  end

  defp sort_key(%DiscoveredDevice{ips: [ip | _ips]}, :address), do: {0, IpAddress.sort_key(ip)}
  defp sort_key(%DiscoveredDevice{macs: [mac | _macs]}, :address), do: {1, mac}
  defp sort_key(%DiscoveredDevice{}, :address), do: nil
end
