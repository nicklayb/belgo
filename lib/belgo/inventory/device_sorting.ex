defmodule Belgo.Inventory.DeviceSorting do
  @moduledoc """
  Sorts the device list by `:name` (case insensitive), `:placement` (the displayed
  placement label) or `:address` (first IP numerically). Devices without the sorted
  value stay last in both directions; ties keep the name order. Pure functions.
  """

  alias Belgo.Inventory.Device
  alias Belgo.Network.IpAddress

  @fields [:name, :placement, :address]
  @directions [:asc, :desc]

  @type field :: :name | :placement | :address
  @type direction :: :asc | :desc
  @typedoc "A device with its placement label, as listed."
  @type row :: {Device.t(), String.t() | nil}

  @doc "The sortable fields."
  @spec fields() :: [field()]
  def fields, do: @fields

  @doc "Parses a field name, `nil` when unknown."
  @spec parse_field(String.t()) :: field() | nil
  def parse_field(name), do: Enum.find(@fields, &(Atom.to_string(&1) == name))

  @doc "Sorts listed devices."
  @spec sort([row()], field(), direction()) :: [row()]
  def sort(rows, field, direction) when field in @fields and direction in @directions do
    {valued, missing} = Enum.split_with(rows, &(sort_key(&1, field) != nil))

    Enum.sort_by(valued, &{sort_key(&1, field), name_key(&1)}, direction) ++
      Enum.sort_by(missing, &name_key/1)
  end

  @doc "Direction after clicking `field`: toggled when already sorted by it, else ascending."
  @spec next({field(), direction()}, field()) :: {field(), direction()}
  def next({field, :asc}, field), do: {field, :desc}
  def next({field, :desc}, field), do: {field, :asc}
  def next(_current, field), do: {field, :asc}

  defp sort_key({device, _placement}, :name), do: String.downcase(device.name)
  defp sort_key({_device, nil}, :placement), do: nil
  defp sort_key({_device, placement}, :placement), do: String.downcase(placement)

  defp sort_key({device, _placement}, :address) do
    case Device.ip_addresses(device) do
      [ip | _ips] -> IpAddress.sort_key(ip)
      [] -> nil
    end
  end

  defp name_key({device, _placement}), do: {String.downcase(device.name), device.id}
end
