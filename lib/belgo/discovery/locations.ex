defmodule Belgo.Discovery.Locations do
  @moduledoc """
  Confronts location observations (Home Assistant floors and areas) with the
  inventory locations. Pure functions only.

  An observation matches the location linked to it by `home_assistant_id`, else an
  unlinked location of the same name (case insensitive). Unmatched observations become
  `DiscoveredLocation`s to claim, their parent resolved when the floor they belong to
  is already in the inventory. Matched ones are checked for divergences: a different
  name (linked locations only) and a floor that is not an ancestor of the location.
  """

  alias Belgo.Discovery.Correlation.Divergence
  alias Belgo.Discovery.Observation
  alias Belgo.Inventory.Identifier
  alias Belgo.Inventory.Location
  alias Belgo.Inventory.Snapshot

  @floor_sort_position 0
  @area_sort_position 1
  @floorless_sort_position 2

  defmodule DiscoveredLocation do
    @moduledoc "A location reported by a provider and missing from the inventory."
    @enforce_keys [:id, :name, :kind, :reference, :observations]
    defstruct [
      :id,
      :name,
      :kind,
      :reference,
      :parent_reference,
      :parent_name,
      :parent_id,
      :level,
      observations: []
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            kind: :floor | :room,
            reference: String.t(),
            parent_reference: String.t() | nil,
            parent_name: String.t() | nil,
            parent_id: String.t() | nil,
            level: integer() | nil,
            observations: [Observation.t()]
          }
  end

  @doc "Returns the new locations and the divergences of the matched ones."
  @spec correlate(Snapshot.t(), [Observation.t()]) :: {[DiscoveredLocation.t()], [Divergence.t()]}
  def correlate(%Snapshot{} = snapshot, observations) do
    observations = Enum.uniq_by(observations, & &1.reference)
    match_by_reference = match(snapshot.locations, observations)

    context = %{
      match_by_reference: match_by_reference,
      observation_by_reference: Map.new(observations, &{&1.reference, &1}),
      location_by_id: Snapshot.index(snapshot, :locations)
    }

    {matched, unmatched} =
      Enum.split_with(observations, &Map.has_key?(match_by_reference, &1.reference))

    new_locations =
      unmatched
      |> Enum.map(&discovered_location(&1, context))
      |> sort(context.observation_by_reference)

    divergences =
      Enum.flat_map(matched, fn observation ->
        divergences(Map.fetch!(match_by_reference, observation.reference), observation, context)
      end)

    {new_locations, divergences}
  end

  @doc "Returns `true` for observations of a floor (as opposed to an area)."
  @spec floor?(Observation.t() | DiscoveredLocation.t()) :: boolean()
  def floor?(%Observation{source: source}), do: source == :home_assistant_floor
  def floor?(%DiscoveredLocation{kind: kind}), do: kind == :floor

  defp match(locations, observations) do
    location_by_reference =
      for location <- locations, location.home_assistant_id != nil, into: %{} do
        {location.home_assistant_id, location}
      end

    location_by_name =
      locations
      |> Enum.filter(&is_nil(&1.home_assistant_id))
      |> Enum.group_by(&normalize(&1.name))

    for observation <- observations,
        location = matching_location(observation, location_by_reference, location_by_name),
        location != nil,
        into: %{},
        do: {observation.reference, location}
  end

  defp matching_location(observation, location_by_reference, location_by_name) do
    case Map.fetch(location_by_reference, observation.reference) do
      {:ok, location} ->
        location

      :error ->
        case Map.get(location_by_name, normalize(observation.name), []) do
          [location] -> location
          _none_or_ambiguous -> nil
        end
    end
  end

  defp discovered_location(observation, context) do
    parent = Map.get(context.observation_by_reference, observation.parent_reference)
    parent_location = Map.get(context.match_by_reference, observation.parent_reference)

    %DiscoveredLocation{
      id: Identifier.slugify(observation.reference),
      name: observation.name,
      kind: if(floor?(observation), do: :floor, else: :room),
      reference: observation.reference,
      parent_reference: observation.parent_reference,
      parent_name: parent && parent.name,
      parent_id: parent_location && parent_location.id,
      level: observation.level,
      observations: [observation]
    }
  end

  defp divergences(location, observation, context) do
    name_divergences(location, observation) ++
      parent_divergences(location, observation, context)
  end

  defp name_divergences(%Location{home_assistant_id: nil}, _observation), do: []

  defp name_divergences(location, observation) do
    if normalize(location.name) == normalize(observation.name),
      do: [],
      else: [
        divergence(
          location,
          observation,
          "name is #{observation.name}, Belgo has #{location.name}"
        )
      ]
  end

  defp parent_divergences(location, observation, context) do
    case Map.fetch(context.match_by_reference, observation.parent_reference) do
      {:ok, floor} ->
        if floor.id in ancestor_ids(location, context.location_by_id),
          do: [],
          else: [
            divergence(
              location,
              observation,
              "is on #{floor.name}, Belgo has it #{placement(location, context.location_by_id)}"
            )
          ]

      :error ->
        []
    end
  end

  defp placement(%Location{parent_id: nil}, _location_by_id), do: "at the top level"

  defp placement(location, location_by_id) do
    case Map.fetch(location_by_id, location.parent_id) do
      {:ok, parent} -> "inside #{parent.name}"
      :error -> "inside #{location.parent_id}"
    end
  end

  defp ancestor_ids(location, location_by_id), do: ancestor_ids(location, location_by_id, [])

  defp ancestor_ids(%Location{parent_id: nil}, _location_by_id, ids), do: ids

  defp ancestor_ids(%Location{parent_id: parent_id}, location_by_id, ids) do
    case {parent_id in ids, Map.fetch(location_by_id, parent_id)} do
      {false, {:ok, parent}} -> ancestor_ids(parent, location_by_id, [parent_id | ids])
      _cycle_or_unknown -> [parent_id | ids]
    end
  end

  defp divergence(location, observation, message) do
    %Divergence{
      collection: :locations,
      id: location.id,
      provider: observation.provider,
      message: message
    }
  end

  defp sort(discovered_locations, observation_by_reference) do
    Enum.sort_by(discovered_locations, fn discovered ->
      floor = floor_of(discovered, observation_by_reference)

      {floor_position(floor), floor && (floor.level || 0), floor && floor.name,
       if(floor?(discovered), do: @floor_sort_position, else: @area_sort_position),
       String.downcase(discovered.name)}
    end)
  end

  defp floor_of(%DiscoveredLocation{kind: :floor} = discovered, observation_by_reference),
    do: Map.get(observation_by_reference, discovered.reference)

  defp floor_of(discovered, observation_by_reference),
    do: Map.get(observation_by_reference, discovered.parent_reference)

  defp floor_position(nil), do: @floorless_sort_position
  defp floor_position(_floor), do: @floor_sort_position

  defp normalize(nil), do: ""

  defp normalize(name),
    do:
      name
      |> String.trim()
      |> String.downcase()
end
