defmodule Belgo.Discovery.OutOfDhcpFilter do
  @moduledoc """
  Filter and order of the *Out of DHCP* devices (`Box.DataFilter`): `query` (IP, MAC,
  name, see `Belgo.Search.discovered_match?/2`), `provider` (a provider key) and the
  sort (`sort` field and `direction`, see `Belgo.Discovery.Sorting`). Defaults are
  left out of the query string.
  """

  use Box.DataFilter,
    fields: [
      query: [],
      provider: [],
      sort: [default: :address],
      direction: [default: :asc]
    ]

  alias Belgo.Discovery.Sorting
  alias Belgo.Search

  @default_sort :address
  @default_direction :asc
  @directions %{"asc" => :asc, "desc" => :desc}

  @type t :: %__MODULE__{}

  @doc "Sorts by `field`, toggling the direction when it is already the sorted field."
  @spec sort_by(t(), Sorting.field()) :: t()
  def sort_by(%Filter{} = filter, field) do
    {sort, direction} = Sorting.next({filter.sort, filter.direction}, field)
    %Filter{filter | sort: sort, direction: direction}
  end

  @impl Box.DataFilter
  def cast(%Filter{}, field, value) when field in [:query, :provider] and is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  def cast(%Filter{}, :sort, value) when is_binary(value),
    do: Sorting.parse_field(value) || @default_sort

  def cast(%Filter{}, :direction, value) when is_binary(value),
    do: Map.get(@directions, value, @default_direction)

  def cast(%Filter{}, :sort, value) when is_atom(value), do: value || @default_sort
  def cast(%Filter{}, :direction, value) when is_atom(value), do: value || @default_direction
  def cast(%Filter{}, _field, _value), do: nil

  @impl Box.DataFilter
  def apply(%Filter{}, devices, field, nil) when field in [:query, :provider], do: devices

  def apply(%Filter{}, devices, :query, query),
    do: Enum.filter(devices, &Search.discovered_match?(&1, query))

  def apply(%Filter{}, devices, :provider, provider) do
    Enum.filter(devices, fn discovered ->
      Enum.any?(discovered.observations, &(Atom.to_string(&1.provider) == provider))
    end)
  end

  def apply(%Filter{direction: direction}, devices, :sort, sort),
    do: Sorting.sort(devices, sort, direction)

  def apply(%Filter{}, devices, :direction, _direction), do: devices

  @impl Box.DataFilter
  def to_query(%Filter{}, _field, nil), do: :ignore
  def to_query(%Filter{}, :sort, @default_sort), do: :ignore
  def to_query(%Filter{}, :direction, @default_direction), do: :ignore
  def to_query(%Filter{}, _field, value) when is_atom(value), do: Atom.to_string(value)
  def to_query(%Filter{}, _field, value), do: value
end
