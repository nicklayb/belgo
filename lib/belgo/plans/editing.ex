defmodule Belgo.Plans.Editing do
  @moduledoc """
  Edits of a plan made by the editor, as pure functions on the `Plan` struct. Each
  returns `{:ok, plan}` (with the created identifier when relevant) or
  `{:error, message}`; the whole plan is validated when saved. Positions are
  snapped to the editor grid by the caller.
  """

  alias Belgo.Inventory.Identifier
  alias Belgo.Plans.Analysis
  alias Belgo.Plans.Geometry
  alias Belgo.Plans.Level
  alias Belgo.Plans.Opening
  alias Belgo.Plans.Placement
  alias Belgo.Plans.Plan
  alias Belgo.Plans.Rectangle
  alias Belgo.Plans.Zone

  @door_width_centimetres 90
  @opening_width_centimetres 120
  @wall_snap_distance_centimetres 40
  @device_wall_snap_centimetres 30
  @default_float_height_centimetres 100
  @adjacent_room_depth_centimetres 300

  @type result :: {:ok, Plan.t()} | {:error, String.t()}

  @doc "A new home without level."
  @spec new_plan(String.t()) :: Plan.t()
  def new_plan(name), do: %Plan{id: Identifier.slugify(name), name: name}

  @doc """
  Adds a level `offset` levels above `base_id` (`nil`: a reference level). With
  `copy_footprint?`, the level starts with one room covering its base level's rooms
  (a floor stacked on another).
  """
  @spec add_level(Plan.t(), String.t(), String.t() | nil, float(), boolean()) ::
          {:ok, Plan.t(), String.t()} | {:error, String.t()}
  def add_level(%Plan{} = plan, name, base_id, offset, copy_footprint?) do
    id = unique_id(name, Enum.map(plan.levels, & &1.id))
    level = %Level{id: id, name: name, base_id: base_id, offset: offset * 1.0}
    plan = %{plan | levels: plan.levels ++ [level]}

    footprint =
      for zone <- plan.zones,
          zone.level_id == base_id,
          base_id != nil,
          rectangle <- zone.rectangles,
          do: rectangle

    if copy_footprint? and footprint != [] do
      {:ok, plan, _zone_id} = add_zone(plan, id, footprint, name)
      {:ok, plan, id}
    else
      {:ok, plan, id}
    end
  end

  @doc "Changes the name, base or offset of a level."
  @spec update_level(Plan.t(), String.t(), map()) :: result()
  def update_level(%Plan{} = plan, level_id, attributes) do
    update_in_list(plan, :levels, level_id, &struct(&1, attributes))
  end

  @doc "Deletes a level with its rooms, their devices and its openings."
  @spec delete_level(Plan.t(), String.t()) :: result()
  def delete_level(%Plan{} = plan, level_id) do
    zone_ids = for zone <- plan.zones, zone.level_id == level_id, do: zone.id

    {:ok,
     %{
       plan
       | levels: Enum.reject(plan.levels, &(&1.id == level_id)),
         zones: Enum.reject(plan.zones, &(&1.id in zone_ids)),
         openings: Enum.reject(plan.openings, &(&1.level_id == level_id)),
         placements: Enum.reject(plan.placements, &(&1.zone_id in zone_ids))
     }}
  end

  @doc "Adds a zone (a room on `level_id`, an exterior zone for `nil`) made of rectangles."
  @spec add_zone(Plan.t(), String.t() | nil, [Geometry.rectangle()], String.t()) ::
          {:ok, Plan.t(), String.t()}
  def add_zone(%Plan{} = plan, level_id, rectangles, name) do
    id = unique_id(name, Enum.map(plan.zones, & &1.id))

    zone = %Zone{
      id: id,
      name: name,
      level_id: level_id,
      rectangles: Enum.map(rectangles, &rectangle/1)
    }

    {:ok, %{plan | zones: plan.zones ++ [zone]}, id}
  end

  @doc "Changes the name or the location of a zone."
  @spec update_zone(Plan.t(), String.t(), map()) :: result()
  def update_zone(%Plan{} = plan, zone_id, attributes) do
    update_in_list(plan, :zones, zone_id, &struct(&1, attributes))
  end

  @doc "Deletes a zone and the devices placed in it."
  @spec delete_zone(Plan.t(), String.t()) :: result()
  def delete_zone(%Plan{} = plan, zone_id) do
    {:ok,
     %{
       plan
       | zones: Enum.reject(plan.zones, &(&1.id == zone_id)),
         placements: Enum.reject(plan.placements, &(&1.zone_id == zone_id))
     }}
  end

  @doc "Replaces a rectangle of a zone (moved or resized)."
  @spec set_rectangle(Plan.t(), String.t(), non_neg_integer(), Geometry.rectangle()) :: result()
  def set_rectangle(%Plan{} = plan, zone_id, index, rectangle) do
    update_in_list(plan, :zones, zone_id, fn zone ->
      %{zone | rectangles: List.replace_at(zone.rectangles, index, rectangle(rectangle))}
    end)
  end

  @doc "Moves a whole zone, with the devices placed in it."
  @spec move_zone(Plan.t(), String.t(), integer(), integer()) :: result()
  def move_zone(%Plan{} = plan, zone_id, delta_x, delta_y) do
    with {:ok, plan} <-
           update_in_list(plan, :zones, zone_id, fn zone ->
             %{zone | rectangles: Enum.map(zone.rectangles, &translate(&1, delta_x, delta_y))}
           end) do
      placements =
        Enum.map(plan.placements, fn
          %{zone_id: ^zone_id} = placement ->
            %{placement | x: placement.x + delta_x, y: placement.y + delta_y}

          placement ->
            placement
        end)

      {:ok, %{plan | placements: placements}}
    end
  end

  @doc "Adds a rectangle to a zone (an L-shaped room); it must touch the zone."
  @spec add_rectangle(Plan.t(), String.t(), Geometry.rectangle()) :: result()
  def add_rectangle(%Plan{} = plan, zone_id, rectangle) do
    update_in_list(plan, :zones, zone_id, fn zone ->
      %{zone | rectangles: zone.rectangles ++ [rectangle(rectangle)]}
    end)
  end

  @doc "Removes a rectangle of a zone; the last one cannot be removed."
  @spec delete_rectangle(Plan.t(), String.t(), non_neg_integer()) :: result()
  def delete_rectangle(%Plan{} = plan, zone_id, index) do
    case find(plan.zones, zone_id) do
      %Zone{rectangles: [_single]} ->
        {:error, "a room keeps at least one rectangle"}

      %Zone{} ->
        update_in_list(
          plan,
          :zones,
          zone_id,
          &%{&1 | rectangles: List.delete_at(&1.rectangles, index)}
        )

      nil ->
        {:error, "unknown zone #{zone_id}"}
    end
  end

  @doc """
  Splits a zone in two along a line (`:vertical` at x = `position`, `:horizontal` at
  y = `position`); the far side becomes a new zone named `name`.
  """
  @spec split_zone(Plan.t(), String.t(), :vertical | :horizontal, integer(), String.t()) ::
          {:ok, Plan.t(), String.t()} | {:error, String.t()}
  def split_zone(%Plan{} = plan, zone_id, axis, position, name) do
    with %Zone{} = zone <- find(plan.zones, zone_id),
         {near, far} = Enum.reduce(zone.rectangles, {[], []}, &cut(&1, axis, position, &2)),
         true <- near != [] and far != [] do
      zones = Enum.map(plan.zones, &if(&1.id == zone_id, do: %{&1 | rectangles: near}, else: &1))
      add_zone(%{plan | zones: zones}, zone.level_id, far, name)
    else
      nil -> {:error, "unknown zone #{zone_id}"}
      false -> {:error, "the line does not cross the room"}
    end
  end

  @doc """
  Adds a door or an opening on the wall nearest to the point (within 40 cm),
  centred on it and kept within the wall.
  """
  @spec add_opening(Plan.t(), Analysis.t(), String.t(), number(), number(), :door | :opening) ::
          result()
  def add_opening(%Plan{} = plan, %Analysis{} = analysis, level_id, x, y, kind) do
    width = if kind == :door, do: @door_width_centimetres, else: @opening_width_centimetres

    case nearest_wall(Map.get(analysis.walls_by_level, level_id, []), x, y) do
      nil ->
        {:error, "click on a wall to place a #{kind}"}

      {axis, position, first, last} ->
        width = min(width, last - first)
        along = if axis == :horizontal, do: x, else: y
        start = min(max(round(along - width / 2), first), last - width)

        {x, y} = if axis == :horizontal, do: {start, position}, else: {position, start}
        opening = %Opening{level_id: level_id, x: x, y: y, axis: axis, width: width, kind: kind}
        {:ok, %{plan | openings: plan.openings ++ [opening]}}
    end
  end

  @doc "Changes the kind or width of the opening at `index`."
  @spec update_opening(Plan.t(), non_neg_integer(), map()) :: result()
  def update_opening(%Plan{} = plan, index, attributes) do
    case Enum.at(plan.openings, index) do
      nil ->
        {:error, "unknown opening"}

      opening ->
        {:ok,
         %{plan | openings: List.replace_at(plan.openings, index, struct(opening, attributes))}}
    end
  end

  @doc "Deletes the opening at `index`."
  @spec delete_opening(Plan.t(), non_neg_integer()) :: result()
  def delete_opening(%Plan{} = plan, index),
    do: {:ok, %{plan | openings: List.delete_at(plan.openings, index)}}

  @doc """
  Moves an orphan room against the nearest room of its level (the smallest move
  closing the gap along x or y), so it joins the home.
  """
  @spec anchor_zone(Plan.t(), String.t()) :: result()
  def anchor_zone(%Plan{} = plan, zone_id) do
    with %Zone{} = zone <- find(plan.zones, zone_id),
         others =
           for(
             other <- plan.zones,
             other.level_id == zone.level_id,
             other.id != zone_id,
             do: other
           ),
         [_ | _] <- others do
      bounds = Geometry.bounds(zone.rectangles)

      {delta_x, delta_y} =
        others
        |> Enum.map(&Geometry.bounds(&1.rectangles))
        |> Enum.flat_map(&gap_moves(bounds, &1))
        |> Enum.min_by(fn {delta_x, delta_y} -> abs(delta_x) + abs(delta_y) end)

      move_zone(plan, zone_id, delta_x, delta_y)
    else
      nil -> {:error, "unknown zone #{zone_id}"}
      [] -> {:error, "no other room on this level to anchor to"}
    end
  end

  @doc """
  Places a device (or moves it) where the editor was clicked on a level (`nil`: the
  exterior): in the room containing the point, on its wall when the point is within
  30 cm of one (snapped onto it, at 150 cm by default), else on its floor. A device
  is placed once: placing it again moves it.
  """
  @spec place_device(Plan.t(), String.t(), String.t() | nil, number(), number()) :: result()
  def place_device(%Plan{} = plan, device_id, level_id, x, y) do
    zones = Enum.filter(plan.zones, &(&1.level_id == level_id))
    previous = Enum.find(plan.placements, &(&1.device_id == device_id))

    case zone_at(zones, x, y) do
      nil ->
        {:error, "click inside a room to place a device"}

      zone ->
        placement = anchored_placement(zone, device_id, x, y, previous)
        others = Enum.reject(plan.placements, &(&1.device_id == device_id))
        {:ok, %{plan | placements: others ++ [placement]}}
    end
  end

  @doc """
  Changes how a placed device is anchored: on a wall it moves onto the nearest wall
  of its room, on the floor its height is 0, floating it keeps a height.
  """
  @spec update_placement(Plan.t(), String.t(), map()) :: result()
  def update_placement(%Plan{} = plan, device_id, attributes) do
    with %Placement{} = placement <- Enum.find(plan.placements, &(&1.device_id == device_id)),
         %Zone{} = zone <- find(plan.zones, placement.zone_id) do
      updated = reanchor(struct(placement, attributes), zone, Map.has_key?(attributes, :anchor))

      placements =
        Enum.map(plan.placements, &if(&1.device_id == device_id, do: updated, else: &1))

      {:ok, %{plan | placements: placements}}
    else
      nil -> {:error, "#{device_id} is not on the plan"}
    end
  end

  @doc "Removes a device from the plan (the device itself is untouched)."
  @spec remove_placement(Plan.t(), String.t()) :: result()
  def remove_placement(%Plan{} = plan, device_id),
    do: {:ok, %{plan | placements: Enum.reject(plan.placements, &(&1.device_id == device_id))}}

  @doc """
  The sides of a zone where another room could be added: segments of its outline
  touching no other zone of its level, each with the room that would extend it
  (the whole side long, `depth` deep outwards), left out when that room would
  overlap another zone.
  """
  @spec free_sides(Plan.t(), String.t(), pos_integer()) :: [
          %{side: :north | :south | :west | :east, x: number(), y: number(), rectangle: map()}
        ]
  def free_sides(%Plan{} = plan, zone_id, depth \\ @adjacent_room_depth_centimetres) do
    case find(plan.zones, zone_id) do
      nil ->
        []

      zone ->
        neighbours =
          for other <- plan.zones,
              other.level_id == zone.level_id,
              other.id != zone_id,
              rectangle <- other.rectangles,
              do: rectangle

        zone.rectangles
        |> Enum.flat_map(&sides/1)
        |> Enum.flat_map(&outer_parts(&1, zone.rectangles))
        |> Enum.reject(&touched?(&1, neighbours))
        |> Enum.map(&adjacent_room(&1, depth))
        |> Enum.reject(fn side ->
          Enum.any?(neighbours, &Geometry.overlap?(side.rectangle, &1))
        end)
    end
  end

  @doc "Adds the room extending the free side at `index` of `free_sides/3`."
  @spec add_adjacent_zone(Plan.t(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, Plan.t(), String.t()} | {:error, String.t()}
  def add_adjacent_zone(%Plan{} = plan, zone_id, index, name) do
    case Enum.at(free_sides(plan, zone_id), index) do
      nil ->
        {:error, "this side is no longer free"}

      side ->
        zone = find(plan.zones, zone_id)
        add_zone(plan, zone.level_id, [side.rectangle], name)
    end
  end

  @doc "Changes the home settings (name, location, heights, ground)."
  @spec update_settings(Plan.t(), map()) :: result()
  def update_settings(%Plan{} = plan, attributes), do: {:ok, struct(plan, attributes)}

  @doc "Snaps a value to the grid step."
  @spec snap(number(), pos_integer()) :: integer()
  def snap(value, grid), do: round(value / grid) * grid

  # The room containing the point, else one whose wall is within reach (a click just
  # outside a wall still targets that wall).
  defp zone_at(zones, x, y) do
    Enum.find(zones, &Geometry.contains_point?(&1.rectangles, x, y)) ||
      Enum.find(
        zones,
        &(nearest_point_on_walls(
            Geometry.outline(&1.rectangles),
            x,
            y,
            @device_wall_snap_centimetres
          ) != nil)
      )
  end

  defp anchored_placement(zone, device_id, x, y, previous) do
    walls = if Zone.exterior?(zone), do: [], else: Geometry.outline(zone.rectangles)

    case nearest_point_on_walls(walls, x, y, @device_wall_snap_centimetres) do
      {wall_x, wall_y} ->
        %Placement{
          device_id: device_id,
          zone_id: zone.id,
          anchor: :wall,
          x: wall_x,
          y: wall_y,
          height: wall_height_of(previous)
        }

      nil ->
        %Placement{
          device_id: device_id,
          zone_id: zone.id,
          anchor: if(previous && previous.anchor == :float, do: :float, else: :floor),
          x: round(x),
          y: round(y),
          height: if(previous && previous.anchor == :float, do: previous.height, else: 0)
        }
    end
  end

  defp wall_height_of(%Placement{anchor: :wall, height: height}), do: height
  defp wall_height_of(_previous), do: Placement.default_wall_height()

  defp reanchor(%Placement{anchor: :wall} = placement, zone, anchor_changed?) do
    walls = Geometry.outline(zone.rectangles)

    case nearest_point_on_walls(walls, placement.x, placement.y, :infinity) do
      {x, y} ->
        height =
          if anchor_changed? and placement.height == 0,
            do: Placement.default_wall_height(),
            else: placement.height

        %{placement | x: x, y: y, height: height}

      nil ->
        placement
    end
  end

  defp reanchor(%Placement{anchor: :floor} = placement, _zone, _anchor_changed?),
    do: %{placement | height: 0}

  defp reanchor(%Placement{anchor: :float, height: 0} = placement, _zone, true),
    do: %{placement | height: @default_float_height_centimetres}

  defp reanchor(placement, _zone, _anchor_changed?), do: placement

  # The closest point of the walls within `reach` (:infinity for any distance).
  defp nearest_point_on_walls(walls, x, y, reach) do
    nearest =
      walls
      |> Enum.map(&closest_point(&1, x, y))
      |> Enum.filter(fn {_point, distance} -> reach == :infinity or distance <= reach end)
      |> Enum.min_by(fn {_point, distance} -> distance end, fn -> nil end)

    case nearest do
      nil -> nil
      {point, _distance} -> point
    end
  end

  defp closest_point(wall, x, y) do
    {point_x, point_y} =
      case wall do
        {:horizontal, wall_y, first, last} -> {min(max(round(x), first), last), wall_y}
        {:vertical, wall_x, first, last} -> {wall_x, min(max(round(y), first), last)}
      end

    {{point_x, point_y}, :math.sqrt((point_x - x) ** 2 + (point_y - y) ** 2)}
  end

  defp sides(rectangle) do
    right = rectangle.x + rectangle.width
    bottom = rectangle.y + rectangle.depth

    [
      {:north, rectangle.y, rectangle.x, right},
      {:south, bottom, rectangle.x, right},
      {:west, rectangle.x, rectangle.y, bottom},
      {:east, right, rectangle.y, bottom}
    ]
  end

  # Parts of a side not shared with another rectangle of the same zone.
  defp outer_parts({side, position, first, last}, rectangles) do
    covered =
      rectangles
      |> Enum.flat_map(&sides/1)
      |> Enum.filter(fn {other_side, other_position, _first, _last} ->
        other_side == opposite(side) and other_position == position
      end)
      |> Enum.map(fn {_side, _position, other_first, other_last} -> {other_first, other_last} end)

    {first, last}
    |> subtract_intervals(covered)
    |> Enum.map(fn {part_first, part_last} -> {side, position, part_first, part_last} end)
  end

  defp subtract_intervals(interval, removed) do
    Enum.reduce(removed, [interval], fn removed_interval, remaining ->
      Enum.flat_map(remaining, &remove_interval(&1, removed_interval))
    end)
  end

  defp remove_interval({first, last}, {removed_first, removed_last}) do
    Enum.filter(
      [{first, min(last, removed_first)}, {max(first, removed_last), last}],
      fn {part_first, part_last} -> part_last > part_first end
    )
  end

  defp touched?({side, position, first, last}, neighbours) do
    Enum.any?(neighbours, fn rectangle ->
      Enum.any?(sides(rectangle), fn {other_side, other_position, other_first, other_last} ->
        other_side == opposite(side) and other_position == position and
          min(last, other_last) > max(first, other_first)
      end)
    end)
  end

  defp opposite(:north), do: :south
  defp opposite(:south), do: :north
  defp opposite(:west), do: :east
  defp opposite(:east), do: :west

  defp adjacent_room({:north, y, first, last}, depth),
    do: %{
      side: :north,
      x: (first + last) / 2,
      y: y,
      rectangle: %{x: first, y: y - depth, width: last - first, depth: depth}
    }

  defp adjacent_room({:south, y, first, last}, depth),
    do: %{
      side: :south,
      x: (first + last) / 2,
      y: y,
      rectangle: %{x: first, y: y, width: last - first, depth: depth}
    }

  defp adjacent_room({:west, x, first, last}, depth),
    do: %{
      side: :west,
      x: x,
      y: (first + last) / 2,
      rectangle: %{x: x - depth, y: first, width: depth, depth: last - first}
    }

  defp adjacent_room({:east, x, first, last}, depth),
    do: %{
      side: :east,
      x: x,
      y: (first + last) / 2,
      rectangle: %{x: x, y: first, width: depth, depth: last - first}
    }

  # Moves placing `bounds` against `other` on each side, aligned on the other axis.
  defp gap_moves(bounds, other) do
    align_y = other.y - bounds.y
    align_x = other.x - bounds.x

    [
      {other.x + other.width - bounds.x, align_y},
      {other.x - (bounds.x + bounds.width), align_y},
      {align_x, other.y + other.depth - bounds.y},
      {align_x, other.y - (bounds.y + bounds.depth)}
    ]
  end

  defp cut(rectangle, :vertical, position, {near, far}) do
    right = rectangle.x + rectangle.width

    cond do
      right <= position ->
        {near ++ [rectangle], far}

      rectangle.x >= position ->
        {near, far ++ [rectangle]}

      true ->
        {near ++ [%{rectangle | width: position - rectangle.x}],
         far ++ [%{rectangle | x: position, width: right - position}]}
    end
  end

  defp cut(rectangle, :horizontal, position, {near, far}) do
    bottom = rectangle.y + rectangle.depth

    cond do
      bottom <= position ->
        {near ++ [rectangle], far}

      rectangle.y >= position ->
        {near, far ++ [rectangle]}

      true ->
        {near ++ [%{rectangle | depth: position - rectangle.y}],
         far ++ [%{rectangle | y: position, depth: bottom - position}]}
    end
  end

  defp nearest_wall(walls, x, y) do
    nearest =
      walls
      |> Enum.map(&{&1, distance(&1, x, y)})
      |> Enum.filter(fn {_wall, distance} -> distance <= @wall_snap_distance_centimetres end)
      |> Enum.min_by(fn {_wall, distance} -> distance end, fn -> nil end)

    case nearest do
      nil -> nil
      {wall, _distance} -> wall
    end
  end

  defp distance({:horizontal, wall_y, first, last}, x, y),
    do: if(x >= first and x <= last, do: abs(y - wall_y), else: :infinity)

  defp distance({:vertical, wall_x, first, last}, x, y),
    do: if(y >= first and y <= last, do: abs(x - wall_x), else: :infinity)

  defp translate(rectangle, delta_x, delta_y),
    do: %{rectangle | x: rectangle.x + delta_x, y: rectangle.y + delta_y}

  defp rectangle(%Rectangle{} = rectangle), do: rectangle

  defp rectangle(%{x: x, y: y, width: width, depth: depth}),
    do: %Rectangle{x: x, y: y, width: width, depth: depth}

  defp find(items, id), do: Enum.find(items, &(&1.id == id))

  defp update_in_list(plan, field, id, function) do
    items = Map.fetch!(plan, field)

    case Enum.find_index(items, &(&1.id == id)) do
      nil -> {:error, "unknown #{field} #{id}"}
      index -> {:ok, Map.put(plan, field, List.update_at(items, index, function))}
    end
  end

  defp unique_id(name, taken) do
    base = Identifier.slugify(name)

    1
    |> Stream.iterate(&(&1 + 1))
    |> Stream.map(fn
      1 -> base
      position -> "#{base}-#{position}"
    end)
    |> Enum.find(&(&1 not in taken))
  end
end
