defmodule Belgo.Plans.Layout do
  @moduledoc """
  Absolute positions of a plan, computed from what is stored (never stored). Pure
  functions.

  Each zone has a frame:

    * a root zone (no anchor) uses the plan's: its rectangles are absolute;
    * an anchored zone's frame starts at the top-left corner of its first
      rectangle, which its `Belgo.Plans.Anchor` places against a wall of its parent;
      its other rectangles are relative to that corner.

  Device placements are in their zone's frame, so they follow their room. Openings
  on a room wall are placed on it by their alignment (`Belgo.Plans.WallPosition`).
  Anchors form a tree resolved from the roots (no constraint solver); an anchor that
  cannot be resolved (unknown parent or rectangle, parent on another level, cycle)
  is reported by `errors/1` and its zone is laid out as a root at the frame origin.
  """

  alias Belgo.Plans.Anchor
  alias Belgo.Plans.Geometry
  alias Belgo.Plans.Opening
  alias Belgo.Plans.Placement
  alias Belgo.Plans.Plan
  alias Belgo.Plans.Rectangle
  alias Belgo.Plans.WallPosition
  alias Belgo.Plans.Zone

  @type origin :: {integer(), integer()}

  @doc """
  The plan with absolute data: zone rectangles, placements and the `level_id`, `x`,
  `y`, `axis` of wall openings (left `nil` when their room or wall is unknown).
  Resolving a resolved plan returns it unchanged. The result is for computing and
  drawing only, never for storing.
  """
  @spec resolve(Plan.t()) :: Plan.t()
  def resolve(%Plan{resolved: true} = plan), do: plan

  def resolve(%Plan{} = plan) do
    origins = origins(plan)
    zones = Enum.map(plan.zones, &absolute_zone(&1, origins))
    zone_by_id = Map.new(zones, &{&1.id, &1})

    %{
      plan
      | resolved: true,
        zones: zones,
        openings: Enum.map(plan.openings, &place_opening(&1, zone_by_id)),
        placements: Enum.map(plan.placements, &absolute_placement(&1, origins))
    }
  end

  @doc """
  The origin of each zone's frame in plan coordinates: `{0, 0}` for roots, the
  corner of the first rectangle for anchored zones.
  """
  @spec origins(Plan.t()) :: %{String.t() => origin()}
  def origins(%Plan{} = plan) do
    zone_by_id = Map.new(plan.zones, &{&1.id, &1})

    Enum.reduce(plan.zones, %{}, fn zone, origins ->
      {_origin, origins} = origin(zone, zone_by_id, origins, [])
      origins
    end)
  end

  @doc "The anchors that cannot be resolved, as `{zone id, message}`."
  @spec errors(Plan.t()) :: [{String.t(), String.t()}]
  def errors(%Plan{} = plan) do
    zone_by_id = Map.new(plan.zones, &{&1.id, &1})

    for %Zone{anchor: %Anchor{}} = zone <- plan.zones,
        message = anchor_error(zone, zone_by_id),
        message != nil,
        do: {zone.id, message}
  end

  @doc "The zones anchored to `zone_id`, directly or not."
  @spec descendant_ids(Plan.t(), String.t()) :: MapSet.t(String.t())
  def descendant_ids(%Plan{} = plan, zone_id) do
    children_by_parent =
      plan.zones
      |> Enum.filter(&Zone.anchored?/1)
      |> Enum.group_by(& &1.anchor.zone_id, & &1.id)

    collect_descendants([zone_id], children_by_parent, MapSet.new())
  end

  @doc """
  The rectangle `width` × `depth` placed by an anchor against the `side` wall of
  the parent rectangle (absolute), outside of it.
  """
  @spec anchored_rectangle(map(), Anchor.t(), pos_integer(), pos_integer()) :: Rectangle.t()
  def anchored_rectangle(parent_rectangle, %Anchor{} = anchor, width, depth) do
    wall = WallPosition.wall(parent_rectangle, anchor.side)
    {_axis, position, _first, _last} = wall
    length = if anchor.side in [:north, :south], do: width, else: depth
    along = WallPosition.low_coordinate(wall, anchor.side, anchor.align, anchor.offset, length)

    case anchor.side do
      :north -> %Rectangle{x: along, y: position - depth, width: width, depth: depth}
      :south -> %Rectangle{x: along, y: position, width: width, depth: depth}
      :west -> %Rectangle{x: position - width, y: along, width: width, depth: depth}
      :east -> %Rectangle{x: position, y: along, width: width, depth: depth}
    end
  end

  @doc """
  The room walls of a resolved plan holding a segment on a level: `{zone, rectangle
  index, side}` for each rectangle side containing it entirely.
  """
  @spec walls_containing(Plan.t(), String.t() | nil, Geometry.segment()) :: [
          {Zone.t(), non_neg_integer(), WallPosition.side()}
        ]
  def walls_containing(%Plan{resolved: true} = plan, level_id, {axis, position, first, last}) do
    for zone <- plan.zones,
        zone.level_id == level_id,
        not Zone.exterior?(zone),
        {rectangle, index} <- Enum.with_index(zone.rectangles),
        side <- WallPosition.sides(),
        {wall_axis, wall_position, wall_first, wall_last} = WallPosition.wall(rectangle, side),
        wall_axis == axis and wall_position == position and wall_first <= first and
          last <= wall_last,
        do: {zone, index, side}
  end

  @doc """
  Puts an opening on the `side` wall of the rectangle at `index` of a resolved zone,
  starting at `low` along it (x or y). Its alignment is kept when it still gives that
  position, else it is aligned on the start.
  """
  @spec put_on_wall(Opening.t(), Zone.t(), non_neg_integer(), WallPosition.side(), integer()) ::
          Opening.t()
  def put_on_wall(%Opening{} = opening, %Zone{} = zone, index, side, low) do
    wall = WallPosition.wall(Enum.at(zone.rectangles, index), side)
    align = keep_align(opening.align, wall, side, low, opening.width)

    Opening.stored(%{
      opening
      | zone_id: zone.id,
        rectangle: stored_index(index),
        side: side,
        align: align,
        offset: WallPosition.offset_for(wall, side, align, low, opening.width)
    })
  end

  @doc "The value stored for a rectangle index (`nil` for the first one, kept out of files)."
  @spec stored_index(non_neg_integer()) :: non_neg_integer() | nil
  def stored_index(0), do: nil
  def stored_index(index), do: index

  # A centred position only stays centred if it is the centre.
  defp keep_align(:center, wall, side, low, length) do
    if WallPosition.low_coordinate(wall, side, :center, nil, length) == low,
      do: :center,
      else: :start
  end

  defp keep_align(nil, _wall, _side, _low, _length), do: :start
  defp keep_align(align, _wall, _side, _low, _length), do: align

  @doc "The index of a rectangle referenced by an anchor or an opening (`nil` is the first)."
  @spec rectangle_index(Anchor.t() | Opening.t()) :: non_neg_integer()
  def rectangle_index(%{rectangle: nil}), do: 0
  def rectangle_index(%{rectangle: index}), do: index

  # Origins are computed from the roots down, memoised; `visiting` detects cycles.
  defp origin(zone, zone_by_id, origins, visiting) do
    case Map.fetch(origins, zone.id) do
      {:ok, origin} ->
        {origin, origins}

      :error ->
        {origin, origins} = compute_origin(zone, zone_by_id, origins, [zone.id | visiting])
        {origin, Map.put(origins, zone.id, origin)}
    end
  end

  defp compute_origin(%Zone{anchor: nil}, _zone_by_id, origins, _visiting), do: {{0, 0}, origins}

  defp compute_origin(%Zone{anchor: anchor} = zone, zone_by_id, origins, visiting) do
    with %Zone{} = parent <- Map.get(zone_by_id, anchor.zone_id),
         true <- parent.level_id == zone.level_id,
         false <- parent.id in visiting,
         %Rectangle{} = parent_rectangle <-
           Enum.at(Zone.frame_rectangles(parent), rectangle_index(anchor)),
         [first | _rest] <- zone.rectangles do
      {parent_origin, origins} = origin(parent, zone_by_id, origins, visiting)
      absolute_parent = translate(parent_rectangle, parent_origin)
      placed = anchored_rectangle(absolute_parent, anchor, first.width, first.depth)
      {{placed.x, placed.y}, origins}
    else
      _unresolvable -> {{0, 0}, origins}
    end
  end

  defp anchor_error(%Zone{anchor: anchor} = zone, zone_by_id) do
    parent = Map.get(zone_by_id, anchor.zone_id)

    cond do
      parent == nil ->
        "#{zone.name}: anchored to unknown room #{anchor.zone_id}"

      parent.level_id != zone.level_id ->
        "#{zone.name}: anchored to #{parent.name}, on another level"

      Enum.at(parent.rectangles, rectangle_index(anchor)) == nil ->
        "#{zone.name}: #{parent.name} has no rectangle #{rectangle_index(anchor) + 1}"

      zone.id in descendant_ids(%Plan{zones: Map.values(zone_by_id)}, zone.id) ->
        "#{zone.name}: anchors form a cycle"

      true ->
        nil
    end
  end

  defp collect_descendants([], _children_by_parent, found), do: found

  defp collect_descendants([zone_id | queue], children_by_parent, found) do
    children = Enum.reject(Map.get(children_by_parent, zone_id, []), &MapSet.member?(found, &1))

    collect_descendants(
      queue ++ children,
      children_by_parent,
      MapSet.union(found, MapSet.new(children))
    )
  end

  defp absolute_zone(zone, origins) do
    origin = Map.get(origins, zone.id, {0, 0})
    rectangles = Enum.map(Zone.frame_rectangles(zone), &translate(&1, origin))
    %{zone | rectangles: rectangles}
  end

  defp translate(rectangle, {origin_x, origin_y}),
    do: %{rectangle | x: (rectangle.x || 0) + origin_x, y: (rectangle.y || 0) + origin_y}

  defp absolute_placement(%Placement{} = placement, origins) do
    {origin_x, origin_y} = Map.get(origins, placement.zone_id, {0, 0})
    %{placement | x: placement.x + origin_x, y: placement.y + origin_y}
  end

  defp place_opening(%Opening{zone_id: nil} = opening, _zone_by_id), do: opening

  defp place_opening(%Opening{} = opening, zone_by_id) do
    with %Zone{} = zone <- Map.get(zone_by_id, opening.zone_id),
         %Rectangle{} = rectangle <- Enum.at(zone.rectangles, rectangle_index(opening)) do
      wall = WallPosition.wall(rectangle, opening.side)
      {axis, position, _first, _last} = wall

      along =
        WallPosition.low_coordinate(
          wall,
          opening.side,
          opening.align,
          opening.offset,
          opening.width
        )

      {x, y} = if axis == :horizontal, do: {along, position}, else: {position, along}
      %{opening | level_id: zone.level_id, axis: axis, x: x, y: y}
    else
      _unknown -> Opening.stored(opening)
    end
  end
end
