defmodule Belgo.Inventory.DeviceFilter do
  @moduledoc """
  Filter of the device list (`Box.DataFilter`): `query` matches the name, hostname,
  tags, IP and MAC addresses and DNS names (case insensitive), `kinds` keeps devices
  of any of the selected kinds (none selected: every kind). Serialised in the query
  string (`kinds=gaming,server`) so the list keeps its filter on back navigation.
  """

  use Box.DataFilter,
    fields: [
      query: [],
      kinds: [default: []]
    ]

  alias Belgo.Inventory.Device

  @kinds_separator ","

  @type t :: %__MODULE__{}

  @doc "Selects a kind, or unselects it when it already is."
  @spec toggle_kind(t(), atom()) :: t()
  def toggle_kind(%Filter{kinds: kinds} = filter, kind) do
    if kind in kinds,
      do: %Filter{filter | kinds: List.delete(kinds, kind)},
      else: %Filter{filter | kinds: kinds ++ [kind]}
  end

  @doc """
  Counts devices by kind, among those matching every criterion but the kinds, so each
  count tells how many devices selecting that kind adds.
  """
  @spec kind_counts(t(), [Device.t()]) :: %{atom() => pos_integer()}
  def kind_counts(%Filter{} = filter, devices) do
    devices
    |> apply_filter(%Filter{filter | kinds: []})
    |> Enum.frequencies_by(& &1.kind)
  end

  @impl Box.DataFilter
  def cast(%Filter{}, :query, query) when is_binary(query) do
    if String.trim(query) == "", do: nil, else: query
  end

  def cast(%Filter{}, :kinds, kinds) when is_binary(kinds),
    do: cast_kinds(String.split(kinds, @kinds_separator, trim: true))

  def cast(%Filter{}, :kinds, kinds) when is_list(kinds), do: cast_kinds(kinds)
  def cast(%Filter{}, :kinds, _kinds), do: []
  def cast(%Filter{}, _field, _value), do: nil

  @impl Box.DataFilter
  def apply(%Filter{}, devices, _field, nil), do: devices
  def apply(%Filter{}, devices, :kinds, []), do: devices

  def apply(%Filter{}, devices, :query, query) do
    normalized = String.downcase(String.trim(query))
    Enum.filter(devices, &matches_query?(&1, normalized))
  end

  def apply(%Filter{}, devices, :kinds, kinds), do: Enum.filter(devices, &(&1.kind in kinds))

  @impl Box.DataFilter
  def to_query(%Filter{}, _field, nil), do: :ignore
  def to_query(%Filter{}, :kinds, []), do: :ignore
  def to_query(%Filter{}, :query, query), do: query

  def to_query(%Filter{}, :kinds, kinds),
    do: Enum.map_join(kinds, @kinds_separator, &Atom.to_string/1)

  defp cast_kinds(names) do
    names
    |> Enum.map(fn name -> Enum.find(Device.kinds(), &(to_string(&1) == to_string(name))) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp matches_query?(device, query) do
    [device.name, Device.hostname(device)]
    |> Kernel.++(device.tags)
    |> Kernel.++(Device.ip_addresses(device))
    |> Kernel.++(Device.dns_names(device))
    |> Kernel.++(for(interface <- device.interfaces, interface.mac, do: interface.mac))
    |> Enum.any?(&(is_binary(&1) and String.contains?(String.downcase(&1), query)))
  end
end
