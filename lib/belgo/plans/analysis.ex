defmodule Belgo.Plans.Analysis do
  @moduledoc """
  Everything computed from a plan, kept in memory (never stored): absolute positions
  (`layout`, see `Belgo.Plans.Layout`), absolute level heights, the ground height,
  walls of each level, measures of each zone, zones disconnected from the rest of
  the home and warnings. Pure functions.

  Anchoring is optional (owner): a root zone keeps its own position and is fine as
  it is; the editor offers to anchor any root other than its level's main room (the
  first root in the plan's order), without warning about it.

  Zones are connected when they share a wall on a level, or when their levels are at
  most one level apart and their footprints touch or overlap (a garage half a level
  above the basement next to it, a floor stacked on the ground floor). The largest
  connected group (by surface) is the home; other rooms are orphans: hidden in 3D
  and reported.
  """

  alias Belgo.Inventory.Snapshot
  alias Belgo.Plans.Geometry
  alias Belgo.Plans.Layout
  alias Belgo.Plans.Levels
  alias Belgo.Plans.Opening
  alias Belgo.Plans.Plan
  alias Belgo.Plans.Zone
  alias Belgo.Topology.Physical

  defmodule Warning do
    @moduledoc "A problem of a plan, shown under it. `kind` lets the editor offer a fix."
    @enforce_keys [:kind, :message]
    defstruct [:kind, :message, :zone_id, :device_id]

    @type kind ::
            :unknown_location
            | :unknown_device
            | :outside_zone
            | :off_wall
            | :opening_off_wall
            | :orphan_zone
            | :anchor_error
            | :location_mismatch
            | :hosted_device

    @type t :: %__MODULE__{
            kind: kind(),
            message: String.t(),
            zone_id: String.t() | nil,
            device_id: String.t() | nil
          }
  end

  defmodule ZoneMeasure do
    @moduledoc "Measures of a zone: surface (square centimetres) and outer bounds."
    defstruct [:area, :bounds, outline: []]

    @type t :: %__MODULE__{
            area: non_neg_integer(),
            bounds: Geometry.rectangle() | nil,
            outline: [Geometry.segment()]
          }
  end

  defstruct layout: nil,
            elevations: %{},
            ground_elevation: 0.0,
            walls_by_level: %{},
            measures: %{},
            orphan_zone_ids: [],
            warnings: []

  @type t :: %__MODULE__{
          layout: Plan.t() | nil,
          elevations: %{String.t() => float()},
          ground_elevation: float(),
          walls_by_level: %{String.t() => [Geometry.segment()]},
          measures: %{String.t() => ZoneMeasure.t()},
          orphan_zone_ids: [String.t()],
          warnings: [Warning.t()]
        }

  @doc """
  Analyses a plan against the inventory (for its links to devices and locations).
  `layout` is the plan resolved to absolute positions, what views draw.
  """
  @spec build(Plan.t(), Snapshot.t()) :: t()
  def build(%Plan{} = stored_plan, %Snapshot{} = snapshot) do
    plan = Layout.resolve(stored_plan)

    elevations =
      case Levels.elevations(plan.levels, plan.level_height) do
        {:ok, elevations} -> elevations
        {:error, _invalid} -> %{}
      end

    walls_by_level = walls_by_level(plan.zones)
    orphan_zone_ids = orphan_zone_ids(plan, elevations)

    analysis = %__MODULE__{
      layout: plan,
      elevations: elevations,
      ground_elevation: ground_elevation(plan, elevations),
      walls_by_level: walls_by_level,
      measures: Map.new(plan.zones, &{&1.id, measure(&1)}),
      orphan_zone_ids: orphan_zone_ids
    }

    %{analysis | warnings: warnings(plan, stored_plan, snapshot, analysis)}
  end

  @doc """
  The root zones of a level other than its main room (the first root in the plan's
  order): the rooms the editor offers to anchor. Exterior zones are left out.
  """
  @spec unanchored_zone_ids(Plan.t()) :: [String.t()]
  def unanchored_zone_ids(%Plan{} = plan) do
    plan.zones
    |> Enum.reject(&(Zone.exterior?(&1) or Zone.anchored?(&1)))
    |> Enum.group_by(& &1.level_id)
    |> Enum.flat_map(fn {_level_id, [_main | others]} -> Enum.map(others, & &1.id) end)
  end

  @doc "The warnings of one device's placement."
  @spec device_warnings(t(), String.t()) :: [Warning.t()]
  def device_warnings(%__MODULE__{warnings: warnings}, device_id),
    do: Enum.filter(warnings, &(&1.device_id == device_id))

  defp ground_elevation(%Plan{ground: nil}, _elevations), do: 0.0

  # The ground is a percentage of its level's own height.
  defp ground_elevation(%Plan{ground: ground} = plan, elevations) do
    height = Map.get(Levels.heights(plan), ground.level_id, plan.level_height)
    Map.get(elevations, ground.level_id, 0.0) + height * ground.percent / 100
  end

  defp walls_by_level(zones) do
    zones
    |> Enum.reject(&Zone.exterior?/1)
    |> Enum.group_by(& &1.level_id)
    |> Map.new(fn {level_id, level_zones} ->
      {level_id, Geometry.merge(Enum.flat_map(level_zones, &Geometry.outline(&1.rectangles)))}
    end)
  end

  defp measure(zone) do
    %ZoneMeasure{
      area: Geometry.area(zone.rectangles),
      bounds: Geometry.bounds(zone.rectangles),
      outline: Geometry.outline(zone.rectangles)
    }
  end

  defp orphan_zone_ids(plan, elevations) do
    rooms = Enum.reject(plan.zones, &Zone.exterior?/1)

    groups =
      rooms
      |> groups(&connected?(&1, &2, elevations, Levels.heights(plan)))
      |> Enum.sort_by(fn group -> -Enum.sum(Enum.map(group, &Geometry.area(&1.rectangles))) end)

    case groups do
      [_home | orphans] ->
        Enum.sort(for orphan_group <- orphans, zone <- orphan_group, do: zone.id)

      [] ->
        []
    end
  end

  defp connected?(left_zone, right_zone, elevations, heights) do
    pairs =
      for left_rectangle <- left_zone.rectangles,
          right_rectangle <- right_zone.rectangles,
          do: {left_rectangle, right_rectangle}

    if left_zone.level_id == right_zone.level_id do
      Enum.any?(pairs, fn {left, right} -> Geometry.touch?(left, right) end)
    else
      close_levels?(left_zone, right_zone, elevations, heights) and
        Enum.any?(pairs, fn {left, right} ->
          Geometry.touch?(left, right) or Geometry.overlap?(left, right)
        end)
    end
  end

  # At most one level apart, measured with the taller of the two levels.
  defp close_levels?(left_zone, right_zone, elevations, heights) do
    with {:ok, left_elevation} <- Map.fetch(elevations, left_zone.level_id),
         {:ok, right_elevation} <- Map.fetch(elevations, right_zone.level_id),
         {:ok, left_height} <- Map.fetch(heights, left_zone.level_id),
         {:ok, right_height} <- Map.fetch(heights, right_zone.level_id) do
      abs(left_elevation - right_elevation) <= max(left_height, right_height)
    else
      :error -> false
    end
  end

  # Connected components of `items` for the `linked?` relation.
  defp groups(items, linked?) do
    {groups, _visited} =
      Enum.reduce(items, {[], MapSet.new()}, fn item, {groups, visited} ->
        if MapSet.member?(visited, item.id) do
          {groups, visited}
        else
          group = reach([item], items, linked?, [item])
          {[group | groups], MapSet.union(visited, MapSet.new(group, & &1.id))}
        end
      end)

    Enum.reverse(groups)
  end

  defp reach([], _items, _linked?, reached), do: reached

  defp reach([current | queue], items, linked?, reached) do
    neighbours = Enum.filter(items, &(&1 not in reached and linked?.(current, &1)))
    reach(queue ++ neighbours, items, linked?, reached ++ neighbours)
  end

  defp warnings(plan, stored_plan, snapshot, analysis) do
    zone_by_id = Map.new(plan.zones, &{&1.id, &1})
    device_by_id = Snapshot.index(snapshot, :devices)
    location_ids = MapSet.new(snapshot.locations, & &1.id)

    location_warnings(plan, location_ids) ++
      Enum.flat_map(
        plan.placements,
        &placement_warnings(&1, zone_by_id, device_by_id, snapshot)
      ) ++
      opening_warnings(plan, analysis) ++
      Enum.map(analysis.orphan_zone_ids, fn zone_id ->
        %Warning{
          kind: :orphan_zone,
          zone_id: zone_id,
          message:
            "#{zone_by_id[zone_id].name} touches no other room: hidden from the 3D view until anchored"
        }
      end) ++ anchor_error_warnings(stored_plan)
  end

  defp anchor_error_warnings(stored_plan) do
    Enum.map(Layout.errors(stored_plan), fn {zone_id, message} ->
      %Warning{kind: :anchor_error, zone_id: zone_id, message: message}
    end)
  end

  defp location_warnings(plan, location_ids) do
    for %{location_id: location_id} = zone <- plan.zones,
        location_id != nil,
        not MapSet.member?(location_ids, location_id) do
      %Warning{
        kind: :unknown_location,
        zone_id: zone.id,
        message: "#{zone.name}: location #{location_id} no longer exists"
      }
    end
  end

  defp placement_warnings(placement, zone_by_id, device_by_id, snapshot) do
    zone = Map.get(zone_by_id, placement.zone_id)

    case Map.fetch(device_by_id, placement.device_id) do
      :error ->
        [
          %Warning{
            kind: :unknown_device,
            device_id: placement.device_id,
            zone_id: placement.zone_id,
            message: "device #{placement.device_id} no longer exists"
          }
        ]

      {:ok, %{host_id: host_id} = device} when is_binary(host_id) ->
        [hosted_warning(placement, device, Map.get(device_by_id, host_id))]

      {:ok, device} when zone != nil ->
        position_warnings(placement, device, zone) ++
          location_mismatch(placement, device, zone, snapshot)

      {:ok, _device} ->
        []
    end
  end

  # A guest (VM, container) is where its host is: it is not placed on its own.
  defp hosted_warning(placement, device, host) do
    %Warning{
      kind: :hosted_device,
      device_id: device.id,
      zone_id: placement.zone_id,
      message:
        "#{device.name} runs on #{(host && host.name) || device.host_id}: place its host instead"
    }
  end

  defp position_warnings(%{anchor: :wall} = placement, device, zone) do
    walls = Geometry.outline(zone.rectangles)

    if Zone.exterior?(zone) or not Geometry.point_on_walls?(walls, placement.x, placement.y),
      do: [
        %Warning{
          kind: :off_wall,
          device_id: device.id,
          zone_id: zone.id,
          message: "#{device.name} is no longer on a wall of #{zone.name}"
        }
      ],
      else: []
  end

  defp position_warnings(placement, device, zone) do
    if Geometry.contains_point?(zone.rectangles, placement.x, placement.y),
      do: [],
      else: [
        %Warning{
          kind: :outside_zone,
          device_id: device.id,
          zone_id: zone.id,
          message: "#{device.name} is outside of #{zone.name}"
        }
      ]
  end

  # Guests are where their host is: their effective location is the host's.
  defp location_mismatch(placement, device, %Zone{location_id: location_id} = zone, snapshot)
       when is_binary(location_id) do
    effective =
      case Physical.device_path(snapshot, device).locations do
        [] -> nil
        locations -> List.last(locations).id
      end

    if effective == location_id,
      do: [],
      else: [
        %Warning{
          kind: :location_mismatch,
          device_id: placement.device_id,
          zone_id: zone.id,
          message:
            "#{device.name} is drawn in #{zone.name}, but its location is #{effective || "not set"}"
        }
      ]
  end

  defp location_mismatch(_placement, _device, _zone, _snapshot), do: []

  defp opening_warnings(plan, analysis) do
    for %Opening{} = opening <- plan.openings,
        segment = Opening.segment(opening),
        segment == nil or
          not Geometry.on_walls?(Map.get(analysis.walls_by_level, opening.level_id, []), segment) do
      %Warning{
        kind: :opening_off_wall,
        zone_id: opening.zone_id,
        message: off_wall_message(opening)
      }
    end
  end

  defp off_wall_message(%Opening{axis: nil} = opening),
    do: "a #{opening.kind} of #{opening.zone_id} has no wall (unknown room or rectangle)"

  defp off_wall_message(opening),
    do: "a #{opening.kind} at #{opening.x}, #{opening.y} is no longer on a wall"
end
