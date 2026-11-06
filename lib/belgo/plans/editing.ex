defmodule Belgo.Plans.Editing do
  @moduledoc """
  Edits of a plan made by the editor, as pure functions on the stored `Plan` struct.
  Each returns `{:ok, plan}` (with the created identifier when relevant) or
  `{:error, message}`; the whole plan is validated when saved. Positions given by
  the editor are absolute (plan centimetres, snapped to the grid by the caller) and
  turned into what is stored (`Belgo.Plans.Layout`):

    * root rooms are moved (with every room anchored to them, directly or not);
      anchored rooms cannot be moved, only resized: their anchored wall stays on
      their parent, they grow away from it, and an edit along that wall changes
      their offset;
    * rooms anchored to a resized room follow its wall; openings follow their wall;
      devices follow their room;
    * deleting a room turns the rooms anchored to it into roots where they were;
      anchoring is optional, they can be anchored again with `anchor_to/5`.
  """

  alias Belgo.Inventory.Identifier
  alias Belgo.Plans.Analysis
  alias Belgo.Plans.Anchor
  alias Belgo.Plans.Geometry
  alias Belgo.Plans.Layout
  alias Belgo.Plans.Level
  alias Belgo.Plans.Opening
  alias Belgo.Plans.Placement
  alias Belgo.Plans.Plan
  alias Belgo.Plans.Rectangle
  alias Belgo.Plans.WallPosition
  alias Belgo.Plans.Zone

  @door_width_centimetres 90
  @opening_width_centimetres 120
  @wall_snap_distance_centimetres 40
  @device_wall_snap_centimetres 30
  @default_float_height_centimetres 100
  @adjacent_room_depth_centimetres 300

  @type result :: {:ok, Plan.t()} | {:error, String.t()}
  @typedoc "A wall of a zone: the index of one of its rectangles and a side of it."
  @type wall :: {non_neg_integer(), WallPosition.side()}

  @doc "A new home without level."
  @spec new_plan(String.t()) :: Plan.t()
  def new_plan(name), do: %Plan{id: Identifier.slugify(name), name: name}

  @doc """
  Adds a level `offset` levels above `base_id` (`nil`: a reference level). With
  `copy_footprint?`, the level starts with one root room covering its base level's
  rooms (a floor stacked on another).
  """
  @spec add_level(Plan.t(), String.t(), String.t() | nil, float(), boolean()) ::
          {:ok, Plan.t(), String.t()} | {:error, String.t()}
  def add_level(%Plan{} = plan, name, base_id, offset, copy_footprint?) do
    id = unique_id(name, Enum.map(plan.levels, & &1.id))
    level = %Level{id: id, name: name, base_id: base_id, offset: offset * 1.0}

    footprint =
      for zone <- Layout.resolve(plan).zones,
          zone.level_id == base_id,
          base_id != nil,
          rectangle <- zone.rectangles,
          do: rectangle

    plan = %{plan | levels: plan.levels ++ [level]}

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
    case Enum.find_index(plan.levels, &(&1.id == level_id)) do
      nil ->
        {:error, "unknown level #{level_id}"}

      index ->
        {:ok, %{plan | levels: List.update_at(plan.levels, index, &struct(&1, attributes))}}
    end
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
         openings:
           Enum.reject(
             plan.openings,
             &(&1.zone_id in zone_ids or (&1.zone_id == nil and &1.level_id == level_id))
           ),
         placements: Enum.reject(plan.placements, &(&1.zone_id in zone_ids))
     }}
  end

  @doc """
  Adds a root zone (a room on `level_id`, an exterior zone for `nil`) made of
  rectangles at absolute positions.
  """
  @spec add_zone(Plan.t(), String.t() | nil, [Geometry.rectangle()], String.t()) ::
          {:ok, Plan.t(), String.t()}
  def add_zone(%Plan{} = plan, level_id, rectangles, name) do
    insert_zone(plan, %Zone{
      name: name,
      level_id: level_id,
      rectangles: Enum.map(rectangles, &rectangle/1)
    })
  end

  @doc "Changes the name or the location of a zone."
  @spec update_zone(Plan.t(), String.t(), map()) :: result()
  def update_zone(%Plan{} = plan, zone_id, attributes) do
    update_zone_with(plan, zone_id, &struct(&1, attributes))
  end

  @doc """
  Deletes a zone and the devices placed in it. Rooms anchored to it become roots
  where they were; its openings move to another room holding the same wall, else
  they go.
  """
  @spec delete_zone(Plan.t(), String.t()) :: result()
  def delete_zone(%Plan{} = plan, zone_id) do
    case find(plan.zones, zone_id) do
      nil ->
        {:error, "unknown zone #{zone_id}"}

      zone ->
        before = Layout.resolve(plan)

        plan =
          plan.zones
          |> Enum.filter(&(&1.anchor && &1.anchor.zone_id == zone_id))
          |> Enum.reduce(plan, &detach(&2, &1.id))

        plan = %{
          plan
          | zones: Enum.reject(plan.zones, &(&1.id == zone_id)),
            placements: Enum.reject(plan.placements, &(&1.zone_id == zone_id))
        }

        neighbour_ids = for other <- plan.zones, other.level_id == zone.level_id, do: other.id
        {:ok, rehome_openings(plan, before, [zone_id], neighbour_ids)}
    end
  end

  @doc """
  Replaces a rectangle of a zone by one at an absolute position (moved or
  resized). An anchored zone's first rectangle keeps its anchored wall on its
  parent: only its size and its position along that wall change.
  """
  @spec set_rectangle(Plan.t(), String.t(), non_neg_integer(), Geometry.rectangle()) :: result()
  def set_rectangle(%Plan{} = plan, zone_id, index, rectangle) do
    with {:ok, world} <- world_rectangles(plan, zone_id),
         true <- index < length(world) do
      world = List.replace_at(world, index, rectangle(rectangle))
      {:ok, put_world_rectangles(plan, zone_id, world)}
    else
      false -> {:error, "unknown rectangle"}
      error -> error
    end
  end

  @doc """
  Moves a root zone with the devices placed in it; the rooms anchored to it follow.
  Anchored zones cannot be moved.
  """
  @spec move_zone(Plan.t(), String.t(), integer(), integer()) :: result()
  def move_zone(%Plan{} = plan, zone_id, delta_x, delta_y) do
    case find(plan.zones, zone_id) do
      nil ->
        {:error, "unknown zone #{zone_id}"}

      %Zone{anchor: %Anchor{}} = zone ->
        {:error, "#{zone.name} is anchored: it follows its parent, change its offset instead"}

      %Zone{} ->
        {:ok, plan} =
          update_zone_with(plan, zone_id, fn zone ->
            %{zone | rectangles: Enum.map(zone.rectangles, &translate(&1, delta_x, delta_y))}
          end)

        {:ok, shift_placements(plan, zone_id, {delta_x, delta_y})}
    end
  end

  @doc "Adds a rectangle (absolute position) to a zone (an L-shaped room); it must touch the zone."
  @spec add_rectangle(Plan.t(), String.t(), Geometry.rectangle()) :: result()
  def add_rectangle(%Plan{} = plan, zone_id, rectangle) do
    with {:ok, world} <- world_rectangles(plan, zone_id) do
      {:ok, put_world_rectangles(plan, zone_id, world ++ [rectangle(rectangle)])}
    end
  end

  @doc """
  Removes a rectangle of a zone; the last one cannot be removed. Removing the first
  rectangle of an anchored zone detaches it (it becomes a root where it is).
  """
  @spec delete_rectangle(Plan.t(), String.t(), non_neg_integer()) :: result()
  def delete_rectangle(%Plan{} = plan, zone_id, index) do
    case find(plan.zones, zone_id) do
      %Zone{rectangles: [_single]} ->
        {:error, "a room keeps at least one rectangle"}

      %Zone{} = zone when index < length(zone.rectangles) ->
        before = Layout.resolve(plan)
        plan = if index == 0 and Zone.anchored?(zone), do: detach(plan, zone_id), else: plan
        {:ok, world} = world_rectangles(plan, zone_id)
        plan = put_world_rectangles(plan, zone_id, List.delete_at(world, index))
        {:ok, rehome(plan, before, [zone_id], [zone_id])}

      %Zone{} ->
        {:error, "unknown rectangle"}

      nil ->
        {:error, "unknown zone #{zone_id}"}
    end
  end

  @doc """
  Splits a zone in two along a line (`:vertical` at x = `position`, `:horizontal` at
  y = `position`): the part holding the zone's anchored wall (the near part of a
  root) stays the zone, the other becomes a new zone named `name`, anchored to it.
  """
  @spec split_zone(Plan.t(), String.t(), :vertical | :horizontal, integer(), String.t()) ::
          {:ok, Plan.t(), String.t()} | {:error, String.t()}
  def split_zone(%Plan{} = plan, zone_id, axis, position, name) do
    before = Layout.resolve(plan)

    with %Zone{} = zone <- find(before.zones, zone_id),
         {near, far} = Enum.reduce(zone.rectangles, {[], []}, &cut(&1, axis, position, &2)),
         true <- near != [] and far != [] do
      {kept, other} = kept_part(zone, near, far)
      plan = put_world_rectangles(plan, zone_id, kept)
      {:ok, plan, new_zone_id} = add_zone(plan, zone.level_id, other, name)

      plan
      |> rehome(before, [zone_id], [zone_id, new_zone_id])
      |> move_placements_inside(before, zone_id, new_zone_id)
      |> anchor_split_part(new_zone_id, zone_id)
    else
      nil -> {:error, "unknown zone #{zone_id}"}
      false -> {:error, "the line does not cross the room"}
    end
  end

  @doc """
  Adds a door or an opening on the room wall nearest to the point (within 40 cm),
  centred on the point and kept within the wall. It is stored on that wall, aligned
  on its start.
  """
  @spec add_opening(Plan.t(), Analysis.t(), String.t(), number(), number(), :door | :opening) ::
          result()
  def add_opening(%Plan{} = plan, %Analysis{} = analysis, level_id, x, y, kind) do
    width = if kind == :door, do: @door_width_centimetres, else: @opening_width_centimetres
    walls = Map.get(analysis.walls_by_level, level_id, [])

    candidates =
      for zone <- Layout.resolve(plan).zones,
          zone.level_id == level_id,
          {rectangle, index} <- Enum.with_index(zone.rectangles),
          side <- WallPosition.sides(),
          candidate = opening_candidate(zone, {rectangle, index, side}, {x, y}, width),
          candidate != nil,
          Geometry.on_walls?(walls, candidate.segment),
          do: candidate

    case Enum.min_by(candidates, & &1.distance, fn -> nil end) do
      nil ->
        {:error, "click on a wall to place a #{kind}"}

      candidate ->
        opening =
          Layout.put_on_wall(
            %Opening{width: candidate.width, kind: kind, align: :start},
            candidate.zone,
            candidate.index,
            candidate.side,
            candidate.low
          )

        {:ok, %{plan | openings: plan.openings ++ [opening]}}
    end
  end

  @doc """
  Changes the kind, width, alignment or offset of the opening at `index`. Changing
  the alignment alone keeps the opening where it is (the offset is recomputed).
  """
  @spec update_opening(Plan.t(), non_neg_integer(), map()) :: result()
  def update_opening(%Plan{} = plan, index, attributes) do
    case Enum.at(plan.openings, index) do
      nil ->
        {:error, "unknown opening"}

      %Opening{zone_id: nil} = opening ->
        attributes = Map.take(attributes, [:kind, :width])

        {:ok,
         %{plan | openings: List.replace_at(plan.openings, index, struct(opening, attributes))}}

      opening ->
        attributes = keep_position(attributes, opening, opening_wall(plan, index))
        updated = normalize_offset(struct(opening, attributes))
        {:ok, %{plan | openings: List.replace_at(plan.openings, index, updated)}}
    end
  end

  @doc "Deletes the opening at `index`."
  @spec delete_opening(Plan.t(), non_neg_integer()) :: result()
  def delete_opening(%Plan{} = plan, index),
    do: {:ok, %{plan | openings: List.delete_at(plan.openings, index)}}

  @doc """
  Anchors a room to the nearest wall of another room of its level (a disconnected
  or not anchored room joins the home): of every way to put one of its rectangles
  against a facing wall, the smallest move not overlapping another room.
  """
  @spec anchor_zone(Plan.t(), String.t()) :: result()
  def anchor_zone(%Plan{} = plan, zone_id) do
    resolved = Layout.resolve(plan)

    with %Zone{} = zone <- find(resolved.zones, zone_id),
         [_ | _] = parents <- anchor_candidates(plan, resolved, zone) do
      others = for other <- resolved.zones, other.level_id == zone.level_id, do: other
      others = Enum.reject(others, &(&1.id == zone_id))

      best =
        parents
        |> Enum.flat_map(&nearest_anchors(zone, &1))
        |> Enum.reject(&overlaps_others?(&1, zone, others))
        |> Enum.min_by(& &1.cost, fn -> nil end)

      if best,
        do: {:ok, attach(plan, resolved, zone_id, best)},
        else: {:error, "no free wall to anchor #{zone.name} to"}
    else
      nil -> {:error, "unknown zone #{zone_id}"}
      [] -> {:error, "no other room on this level to anchor to"}
    end
  end

  @doc """
  Anchors a room by one of its walls (`{rectangle index, side}`) to a facing wall
  of another room of its level (the parent's opposite side): the room moves across
  to lie against it, keeping its position along it (aligned on its start).
  """
  @spec anchor_to(Plan.t(), String.t(), wall(), String.t(), wall()) :: result()
  def anchor_to(%Plan{} = plan, zone_id, {own_index, own_side}, parent_id, {parent_index, side}) do
    resolved = Layout.resolve(plan)
    zone = find(resolved.zones, zone_id)
    parent = find(resolved.zones, parent_id)

    case anchoring_error(plan, zone, parent, own_side == WallPosition.opposite(side)) do
      nil ->
        with %Rectangle{} = own <- Enum.at(zone.rectangles, own_index),
             %Rectangle{} = parent_rectangle <- Enum.at(parent.rectangles, parent_index) do
          wall = WallPosition.wall(parent_rectangle, side)
          length = length_along(own, side)
          offset = WallPosition.offset_for(wall, side, :start, along(own, side), length)

          {:ok,
           attach(plan, resolved, zone_id, %{
             own_index: own_index,
             parent_id: parent_id,
             parent_index: parent_index,
             side: side,
             offset: offset
           })}
        else
          nil -> {:error, "unknown wall"}
        end

      message ->
        {:error, message}
    end
  end

  @doc "Turns an anchored room into a root where it is (it no longer follows its parent)."
  @spec detach_zone(Plan.t(), String.t()) :: result()
  def detach_zone(%Plan{} = plan, zone_id) do
    case find(plan.zones, zone_id) do
      nil -> {:error, "unknown zone #{zone_id}"}
      _zone -> {:ok, detach(plan, zone_id)}
    end
  end

  @doc """
  Changes how an anchored room sits along its parent's wall (`align`, `offset`).
  Changing the alignment alone keeps the room where it is.
  """
  @spec update_anchor(Plan.t(), String.t(), map()) :: result()
  def update_anchor(%Plan{} = plan, zone_id, attributes) do
    resolved = Layout.resolve(plan)

    case find(plan.zones, zone_id) do
      %Zone{anchor: %Anchor{} = anchor} ->
        first = hd(find(resolved.zones, zone_id).rectangles)

        position =
          case parent_wall(resolved, anchor) do
            nil -> nil
            wall -> {wall, along(first, anchor.side), length_along(first, anchor.side)}
          end

        anchor = normalize_offset(struct(anchor, keep_position(attributes, anchor, position)))
        update_zone_with(plan, zone_id, &%{&1 | anchor: anchor})

      %Zone{} ->
        {:error, "this room is not anchored"}

      nil ->
        {:error, "unknown zone #{zone_id}"}
    end
  end

  @doc """
  Places a device (or moves it) where the editor was clicked on a level (`nil`: the
  exterior): in the room containing the point, on its wall when the point is within
  30 cm of one (snapped onto it, at 150 cm by default), else on its floor. A device
  is placed once: placing it again moves it. It is stored in its room's frame.
  """
  @spec place_device(Plan.t(), String.t(), String.t() | nil, number(), number()) :: result()
  def place_device(%Plan{} = plan, device_id, level_id, x, y) do
    zones = Enum.filter(Layout.resolve(plan).zones, &(&1.level_id == level_id))
    previous = Enum.find(plan.placements, &(&1.device_id == device_id))

    case zone_at(zones, x, y) do
      nil ->
        {:error, "click inside a room to place a device"}

      zone ->
        placement = to_frame(anchored_placement(zone, device_id, {x, y}, previous), plan)
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
    resolved = Layout.resolve(plan)

    with %Placement{} = placement <-
           Enum.find(resolved.placements, &(&1.device_id == device_id)),
         %Zone{} = zone <- find(resolved.zones, placement.zone_id) do
      updated =
        placement
        |> struct(attributes)
        |> reanchor(zone, Map.has_key?(attributes, :anchor))
        |> to_frame(plan)

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
  (absolute) touching no other zone of its level, each with the room that would
  extend it (the whole segment long, `depth` deep outwards) and the wall it would be
  anchored to (`parent_rectangle` index, `first` / `last` of the segment), left out
  when that room would overlap another zone.
  """
  @spec free_sides(Plan.t(), String.t(), pos_integer()) :: [
          %{
            side: WallPosition.side(),
            x: number(),
            y: number(),
            rectangle: map(),
            parent_rectangle: non_neg_integer(),
            first: integer(),
            last: integer()
          }
        ]
  def free_sides(%Plan{} = plan, zone_id, depth \\ @adjacent_room_depth_centimetres) do
    resolved = Layout.resolve(plan)

    case find(resolved.zones, zone_id) do
      nil ->
        []

      zone ->
        neighbours =
          for other <- resolved.zones,
              other.level_id == zone.level_id,
              other.id != zone_id,
              rectangle <- other.rectangles,
              do: rectangle

        zone.rectangles
        |> Enum.with_index()
        |> Enum.flat_map(fn {rectangle, index} -> sides(rectangle, index) end)
        |> Enum.flat_map(&outer_parts(&1, zone.rectangles))
        |> Enum.reject(&touched?(&1, neighbours))
        |> Enum.map(&adjacent_room(&1, depth))
        |> Enum.reject(fn side ->
          Enum.any?(neighbours, &Geometry.overlap?(side.rectangle, &1))
        end)
    end
  end

  @doc """
  Adds the room extending the free side at `index` of `free_sides/3`, anchored to
  that wall (aligned on its start, at the segment's start).
  """
  @spec add_adjacent_zone(Plan.t(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, Plan.t(), String.t()} | {:error, String.t()}
  def add_adjacent_zone(%Plan{} = plan, zone_id, index, name) do
    case Enum.at(free_sides(plan, zone_id), index) do
      nil ->
        {:error, "this side is no longer free"}

      side ->
        parent = find(Layout.resolve(plan).zones, zone_id)
        wall = WallPosition.wall(Enum.at(parent.rectangles, side.parent_rectangle), side.side)
        length = side.last - side.first

        insert_zone(plan, %Zone{
          name: name,
          level_id: parent.level_id,
          anchor: %Anchor{
            zone_id: zone_id,
            rectangle: Layout.stored_index(side.parent_rectangle),
            side: side.side,
            align: :start,
            offset: WallPosition.offset_for(wall, side.side, :start, side.first, length)
          },
          rectangles: [%Rectangle{width: side.rectangle.width, depth: side.rectangle.depth}]
        })
    end
  end

  @doc "Changes the home settings (name, location, heights, ground)."
  @spec update_settings(Plan.t(), map()) :: result()
  def update_settings(%Plan{} = plan, attributes), do: {:ok, struct(plan, attributes)}

  @doc "Snaps a value to the grid step."
  @spec snap(number(), pos_integer()) :: integer()
  def snap(value, grid), do: round(value / grid) * grid

  # Frames --------------------------------------------------------------------

  defp world_rectangles(plan, zone_id) do
    case find(Layout.resolve(plan).zones, zone_id) do
      nil -> {:error, "unknown zone #{zone_id}"}
      zone -> {:ok, zone.rectangles}
    end
  end

  # Stores absolute rectangles for a zone. Roots store them as they are; anchored
  # zones keep their anchored wall on their parent (their first rectangle's position
  # along it becomes the offset) and store the others relative to the first one.
  # Devices of the zone keep their absolute position.
  defp put_world_rectangles(plan, zone_id, [first | rest] = world) do
    zone = find(plan.zones, zone_id)
    old_origin = Map.get(Layout.origins(plan), zone_id, {0, 0})

    {zone, new_origin} =
      case {zone.anchor, resolvable_parent_rectangle(plan, zone)} do
        {nil, _parent_rectangle} ->
          {%{zone | rectangles: Enum.map(world, &rectangle/1)}, {0, 0}}

        {_unresolvable, nil} ->
          {%{zone | rectangles: anchored_rectangles(first, rest, {0, 0})}, {0, 0}}

        {anchor, parent_rectangle} ->
          wall = WallPosition.wall(parent_rectangle, anchor.side)

          anchor =
            realign(anchor, wall, along(first, anchor.side), length_along(first, anchor.side))

          placed = Layout.anchored_rectangle(parent_rectangle, anchor, first.width, first.depth)
          origin = {placed.x, placed.y}
          {%{zone | anchor: anchor, rectangles: anchored_rectangles(first, rest, origin)}, origin}
      end

    plan
    |> replace_zone(zone)
    |> shift_placements(zone_id, difference(old_origin, new_origin))
  end

  defp anchored_rectangles(first, rest, origin),
    do: [
      %Rectangle{width: first.width, depth: first.depth} | Enum.map(rest, &relative(&1, origin))
    ]

  # The absolute parent rectangle of an anchored zone whose anchor resolves.
  defp resolvable_parent_rectangle(_plan, %Zone{anchor: nil}), do: nil

  defp resolvable_parent_rectangle(plan, %Zone{anchor: anchor} = zone) do
    if List.keymember?(Layout.errors(plan), zone.id, 0) do
      nil
    else
      parent = find(Layout.resolve(plan).zones, anchor.zone_id)
      Enum.at(parent.rectangles, Layout.rectangle_index(anchor))
    end
  end

  # The anchor keeps its alignment, its offset follows the rectangle along the wall
  # (centred rooms stay centred).
  defp realign(%Anchor{align: :center} = anchor, _wall, _low, _length), do: anchor

  defp realign(%Anchor{} = anchor, wall, low, length),
    do: %{anchor | offset: WallPosition.offset_for(wall, anchor.side, anchor.align, low, length)}

  # Turns a zone into a root where it is drawn; its devices keep their position.
  defp detach(plan, zone_id) do
    world_zone = find(Layout.resolve(plan).zones, zone_id)
    origin = Map.get(Layout.origins(plan), zone_id, {0, 0})
    zone = find(plan.zones, zone_id)
    rectangles = Enum.map(world_zone.rectangles, &rectangle/1)

    plan
    |> replace_zone(%{zone | anchor: nil, rectangles: rectangles})
    |> shift_placements(zone_id, origin)
  end

  defp anchoring_error(_plan, zone, parent, _facing?) when zone == nil or parent == nil,
    do: "unknown room"

  defp anchoring_error(plan, zone, parent, facing?) do
    cond do
      zone.id == parent.id or MapSet.member?(Layout.descendant_ids(plan, zone.id), parent.id) ->
        "#{zone.name} cannot be anchored to itself or to a room anchored to it"

      zone.level_id != parent.level_id ->
        "#{parent.name} is on another level"

      not facing? ->
        "the walls must face each other: pick opposite sides"

      true ->
        nil
    end
  end

  # Anchors a zone by its rectangle `own_index` to the `side` wall of the parent's
  # rectangle `parent_index` at `offset` (aligned on the start): the zone moves with
  # its devices, its rectangles are reordered so that the anchored one comes first.
  defp attach(plan, resolved, zone_id, choice) do
    world_zone = find(resolved.zones, zone_id)
    own = Enum.at(world_zone.rectangles, choice.own_index)
    old_origin = Map.get(Layout.origins(plan), zone_id, {0, 0})
    corner = {own.x, own.y}
    zone = find(plan.zones, zone_id)

    anchor = %Anchor{
      zone_id: choice.parent_id,
      rectangle: Layout.stored_index(choice.parent_index),
      side: choice.side,
      align: :start,
      offset: choice.offset
    }

    others = List.delete_at(world_zone.rectangles, choice.own_index)

    plan
    |> replace_zone(%{
      zone
      | anchor: anchor,
        rectangles: anchored_rectangles(own, others, corner)
    })
    |> shift_placements(zone_id, difference(old_origin, corner))
    |> reindex(zone_id, &moved_first(&1, choice.own_index))
  end

  defp moved_first(index, index), do: 0
  defp moved_first(index, moved) when index < moved, do: index + 1
  defp moved_first(index, _moved), do: index

  # Renumbers the rectangles of a zone referenced by anchors and openings.
  defp reindex(plan, zone_id, renumber) do
    zones =
      Enum.map(plan.zones, fn
        %Zone{anchor: %Anchor{zone_id: ^zone_id} = anchor} = zone ->
          %{zone | anchor: renumbered(anchor, renumber)}

        zone ->
          zone
      end)

    openings =
      Enum.map(plan.openings, fn
        %Opening{zone_id: ^zone_id} = opening -> renumbered(opening, renumber)
        opening -> opening
      end)

    %{plan | zones: zones, openings: openings}
  end

  defp renumbered(item, renumber) do
    index = renumber.(Layout.rectangle_index(item))
    %{item | rectangle: Layout.stored_index(index)}
  end

  # After the rectangles of `zone_ids` changed, rooms anchored to them and their
  # openings are put back on the wall (of `candidate_ids`) where they were; rooms
  # without such a wall become roots where they were, openings without one go.
  defp rehome(plan, before, zone_ids, candidate_ids) do
    plan
    |> rehome_children(before, zone_ids, candidate_ids)
    |> rehome_openings(before, zone_ids, candidate_ids)
  end

  defp rehome_children(plan, before, zone_ids, candidate_ids) do
    resolved = Layout.resolve(plan)

    plan.zones
    |> Enum.filter(&(&1.anchor && &1.anchor.zone_id in zone_ids))
    |> Enum.reduce(plan, fn child, accumulator ->
      first = hd(find(before.zones, child.id).rectangles)
      side = child.anchor.side
      edge = WallPosition.wall(first, WallPosition.opposite(side))

      case best_wall(resolved, candidate_ids, side, edge) do
        nil ->
          restore_as_root(accumulator, before, child.id)

        {parent, index} ->
          wall = WallPosition.wall(Enum.at(parent.rectangles, index), side)
          anchor = %{child.anchor | zone_id: parent.id, rectangle: Layout.stored_index(index)}
          anchor = realign_keeping(anchor, wall, along(first, side), length_along(first, side))
          replace_zone(accumulator, %{find(accumulator.zones, child.id) | anchor: anchor})
      end
    end)
  end

  # The wall (zone, rectangle index) on the edge's line overlapping it the most.
  defp best_wall(resolved, candidate_ids, side, {axis, position, first, last}) do
    candidates =
      for zone <- resolved.zones,
          zone.id in candidate_ids,
          {rectangle, index} <- Enum.with_index(zone.rectangles),
          {wall_axis, wall_position, wall_first, wall_last} = WallPosition.wall(rectangle, side),
          wall_axis == axis and wall_position == position,
          overlap = min(last, wall_last) - max(first, wall_first),
          overlap > 0,
          do: {overlap, zone, index}

    case Enum.max_by(candidates, &elem(&1, 0), fn -> nil end) do
      nil -> nil
      {_overlap, zone, index} -> {zone, index}
    end
  end

  defp realign_keeping(%Anchor{} = anchor, wall, low, length) do
    centred? = WallPosition.low_coordinate(wall, anchor.side, :center, nil, length) == low
    align = if anchor.align == :center and not centred?, do: :start, else: anchor.align
    offset = WallPosition.offset_for(wall, anchor.side, align, low, length)
    %{anchor | align: align, offset: offset}
  end

  # An anchored room becomes a root at the position it had in `before`; its devices
  # were relative to its first rectangle there.
  defp restore_as_root(plan, before, zone_id) do
    world_zone = find(before.zones, zone_id)
    first = hd(world_zone.rectangles)
    zone = find(plan.zones, zone_id)
    rectangles = Enum.map(world_zone.rectangles, &rectangle/1)

    plan
    |> replace_zone(%{zone | anchor: nil, rectangles: rectangles})
    |> shift_placements(zone_id, {first.x, first.y})
  end

  defp rehome_openings(plan, before, zone_ids, candidate_ids) do
    resolved = Layout.resolve(plan)

    openings =
      plan.openings
      |> Enum.zip(before.openings)
      |> Enum.flat_map(fn {opening, placed} ->
        if opening.zone_id != nil and opening.zone_id in zone_ids,
          do: rehome_opening(opening, placed, resolved, candidate_ids),
          else: [opening]
      end)

    %{plan | openings: openings}
  end

  defp rehome_opening(opening, placed, resolved, candidate_ids) do
    case Opening.segment(placed) do
      nil ->
        []

      {_axis, _position, first, _last} = segment ->
        resolved
        |> Layout.walls_containing(placed.level_id, segment)
        |> Enum.filter(fn {zone, _index, _side} -> zone.id in candidate_ids end)
        |> Enum.take(1)
        |> Enum.map(fn {zone, index, side} ->
          Layout.put_on_wall(opening, zone, index, side, first)
        end)
    end
  end

  # Splitting ------------------------------------------------------------------

  # The part keeping the zone: the one holding a piece of its first rectangle on its
  # anchored edge (that piece first), else the near one for a root.
  defp kept_part(%Zone{anchor: nil}, near, far), do: {near, far}

  defp kept_part(%Zone{anchor: anchor, rectangles: [first | _rest]}, near, far) do
    edge_side = WallPosition.opposite(anchor.side)
    {axis, position, edge_first, edge_last} = WallPosition.wall(first, edge_side)

    holds_edge? = fn rectangle ->
      {wall_axis, wall_position, wall_first, wall_last} = WallPosition.wall(rectangle, edge_side)

      wall_axis == axis and wall_position == position and
        min(edge_last, wall_last) > max(edge_first, wall_first) and
        Geometry.overlap?(rectangle, first)
    end

    {kept, other} = if Enum.any?(near, holds_edge?), do: {near, far}, else: {far, near}
    {anchored, rest} = Enum.split_with(kept, holds_edge?)
    {anchored ++ rest, other}
  end

  # Devices standing in the new part move to it (keeping their absolute position).
  defp move_placements_inside(plan, before, zone_id, new_zone_id) do
    resolved = Layout.resolve(plan)
    new_zone = find(resolved.zones, new_zone_id)
    kept_zone = find(resolved.zones, zone_id)
    world_by_device = Map.new(before.placements, &{&1.device_id, &1})

    placements =
      Enum.map(plan.placements, fn
        %Placement{zone_id: ^zone_id} = placement ->
          world = world_by_device[placement.device_id]

          if Geometry.contains_point?(new_zone.rectangles, world.x, world.y) and
               not Geometry.contains_point?(kept_zone.rectangles, world.x, world.y),
             do: %{world | zone_id: new_zone_id},
             else: placement

        placement ->
          placement
      end)

    %{plan | placements: placements}
  end

  # The new part of a split is anchored to the kept one along the cut.
  defp anchor_split_part(plan, new_zone_id, zone_id) do
    resolved = Layout.resolve(plan)
    new_zone = find(resolved.zones, new_zone_id)

    pair =
      for {rectangle, own_index} <- Enum.with_index(new_zone.rectangles),
          side <- WallPosition.sides(),
          edge = WallPosition.wall(rectangle, WallPosition.opposite(side)),
          {_kept, parent_index} <- [best_wall(resolved, [zone_id], side, edge)],
          reduce: nil do
        nil -> {own_index, side, parent_index}
        found -> found
      end

    case pair do
      {own_index, side, parent_index} ->
        own_wall = {own_index, WallPosition.opposite(side)}
        {:ok, plan} = anchor_to(plan, new_zone_id, own_wall, zone_id, {parent_index, side})
        {:ok, plan, new_zone_id}

      nil ->
        {:ok, plan, new_zone_id}
    end
  end

  # Anchoring to the nearest wall ------------------------------------------------

  defp anchor_candidates(plan, resolved, zone) do
    descendants = Layout.descendant_ids(plan, zone.id)

    for other <- resolved.zones,
        other.level_id == zone.level_id,
        other.id != zone.id,
        not MapSet.member?(descendants, other.id),
        do: other
  end

  # Every way to put a rectangle of `zone` against a facing wall of `parent`,
  # overlapping it as much as possible from where it is, with the move it costs.
  defp nearest_anchors(zone, parent) do
    for {own, own_index} <- Enum.with_index(zone.rectangles),
        {parent_rectangle, parent_index} <- Enum.with_index(parent.rectangles),
        side <- WallPosition.sides() do
      wall = WallPosition.wall(parent_rectangle, side)
      {_axis, _position, first, last} = wall
      length = length_along(own, side)
      offset = WallPosition.offset_for(wall, side, :start, along(own, side), length)
      offset = clamp(offset, 0, last - first - length)
      anchor = %Anchor{zone_id: parent.id, side: side, align: :start, offset: offset}
      placed = Layout.anchored_rectangle(parent_rectangle, anchor, own.width, own.depth)
      {delta_x, delta_y} = {placed.x - own.x, placed.y - own.y}

      %{
        own_index: own_index,
        parent_id: parent.id,
        parent_index: parent_index,
        side: side,
        offset: offset,
        delta: {delta_x, delta_y},
        cost: abs(delta_x) + abs(delta_y)
      }
    end
  end

  defp clamp(value, low, high) when high < low, do: clamp(value, high, low)
  defp clamp(value, low, high), do: min(max(value, low), high)

  defp overlaps_others?(%{delta: {delta_x, delta_y}}, zone, others) do
    moved = Enum.map(zone.rectangles, &translate(&1, delta_x, delta_y))

    for other <- others, rectangle <- other.rectangles, reduce: false do
      found -> found or Enum.any?(moved, &Geometry.overlap?(&1, rectangle))
    end
  end

  # Openings -------------------------------------------------------------------

  defp opening_candidate(zone, {rectangle, index, side}, {x, y}, width) do
    {axis, position, first, last} = WallPosition.wall(rectangle, side)
    {along, across} = if axis == :horizontal, do: {x, y}, else: {y, x}
    distance = abs(across - position)

    if along >= first and along <= last and distance <= @wall_snap_distance_centimetres do
      width = min(width, last - first)
      low = min(max(round(along - width / 2), first), last - width)

      %{
        zone: zone,
        index: index,
        side: side,
        low: low,
        width: width,
        segment: {axis, position, low, low + width},
        distance: distance
      }
    end
  end

  # The wall of a placed wall opening, its position and length along it.
  defp opening_wall(plan, index) do
    resolved = Layout.resolve(plan)
    placed = Enum.at(resolved.openings, index)

    with %Opening{axis: axis} when axis != nil <- placed,
         %Zone{} = zone <- find(resolved.zones, placed.zone_id),
         %Rectangle{} = rectangle <- Enum.at(zone.rectangles, Layout.rectangle_index(placed)) do
      low = if axis == :horizontal, do: placed.x, else: placed.y
      {WallPosition.wall(rectangle, placed.side), low, placed.width}
    else
      _unknown -> nil
    end
  end

  # A new alignment without offset keeps the position along the wall.
  defp keep_position(%{align: align} = attributes, item, {wall, low, length})
       when not is_map_key(attributes, :offset) do
    Map.put(attributes, :offset, WallPosition.offset_for(wall, item.side, align, low, length))
  end

  defp keep_position(attributes, _item, _position), do: attributes

  defp normalize_offset(%{align: :center} = item), do: %{item | offset: nil}
  defp normalize_offset(%{offset: nil} = item), do: %{item | offset: 0}
  defp normalize_offset(item), do: item

  defp parent_wall(resolved, %Anchor{} = anchor) do
    with %Zone{} = parent <- find(resolved.zones, anchor.zone_id),
         %Rectangle{} = rectangle <- Enum.at(parent.rectangles, Layout.rectangle_index(anchor)) do
      WallPosition.wall(rectangle, anchor.side)
    else
      _unknown -> nil
    end
  end

  # Devices --------------------------------------------------------------------

  # The room containing the point, else one whose wall is within reach (a click just
  # outside a wall still targets that wall).
  defp zone_at(zones, x, y) do
    Enum.find(zones, &Geometry.contains_point?(&1.rectangles, x, y)) ||
      Enum.find(
        zones,
        &(nearest_point_on_walls(
            Geometry.outline(&1.rectangles),
            {x, y},
            @device_wall_snap_centimetres
          ) != nil)
      )
  end

  # An absolute placement turned into its zone's frame.
  defp to_frame(%Placement{} = placement, plan) do
    {origin_x, origin_y} = Map.get(Layout.origins(plan), placement.zone_id, {0, 0})
    %{placement | x: placement.x - origin_x, y: placement.y - origin_y}
  end

  defp anchored_placement(zone, device_id, {x, y}, previous) do
    walls = if Zone.exterior?(zone), do: [], else: Geometry.outline(zone.rectangles)
    floating? = previous != nil and previous.anchor == :float

    case nearest_point_on_walls(walls, {x, y}, @device_wall_snap_centimetres) do
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
          anchor: if(floating?, do: :float, else: :floor),
          x: round(x),
          y: round(y),
          height: if(floating?, do: previous.height, else: 0)
        }
    end
  end

  defp wall_height_of(%Placement{anchor: :wall, height: height}), do: height
  defp wall_height_of(_previous), do: Placement.default_wall_height()

  defp reanchor(%Placement{anchor: :wall} = placement, zone, anchor_changed?) do
    walls = Geometry.outline(zone.rectangles)

    case nearest_point_on_walls(walls, {placement.x, placement.y}, :infinity) do
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
  defp nearest_point_on_walls(walls, {x, y}, reach) do
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

  defp shift_placements(plan, _zone_id, {0, 0}), do: plan

  defp shift_placements(plan, zone_id, {delta_x, delta_y}) do
    placements =
      Enum.map(plan.placements, fn
        %{zone_id: ^zone_id} = placement ->
          %{placement | x: placement.x + delta_x, y: placement.y + delta_y}

        placement ->
          placement
      end)

    %{plan | placements: placements}
  end

  # Free sides -------------------------------------------------------------------

  defp sides(rectangle, index) do
    right = rectangle.x + rectangle.width
    bottom = rectangle.y + rectangle.depth

    [
      {:north, rectangle.y, rectangle.x, right, index},
      {:south, bottom, rectangle.x, right, index},
      {:west, rectangle.x, rectangle.y, bottom, index},
      {:east, right, rectangle.y, bottom, index}
    ]
  end

  # Parts of a side not shared with another rectangle of the same zone.
  defp outer_parts({side, position, first, last, index}, rectangles) do
    covered =
      for {rectangle, other_index} <- Enum.with_index(rectangles),
          {other_side, other_position, other_first, other_last, _index} <-
            sides(rectangle, other_index),
          other_side == WallPosition.opposite(side) and other_position == position,
          do: {other_first, other_last}

    {first, last}
    |> subtract_intervals(covered)
    |> Enum.map(fn {part_first, part_last} -> {side, position, part_first, part_last, index} end)
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

  defp touched?({side, position, first, last, _index}, neighbours) do
    for rectangle <- neighbours,
        {other_side, other_position, other_first, other_last, _index} <- sides(rectangle, 0),
        reduce: false do
      found ->
        found or
          (other_side == WallPosition.opposite(side) and other_position == position and
             min(last, other_last) > max(first, other_first))
    end
  end

  defp adjacent_room({side, position, first, last, index}, depth) do
    rectangle =
      case side do
        :north -> %{x: first, y: position - depth, width: last - first, depth: depth}
        :south -> %{x: first, y: position, width: last - first, depth: depth}
        :west -> %{x: position - depth, y: first, width: depth, depth: last - first}
        :east -> %{x: position, y: first, width: depth, depth: last - first}
      end

    {x, y} =
      if side in [:north, :south],
        do: {(first + last) / 2, position},
        else: {position, (first + last) / 2}

    %{
      side: side,
      x: x,
      y: y,
      rectangle: rectangle,
      parent_rectangle: index,
      first: first,
      last: last
    }
  end

  # Helpers --------------------------------------------------------------------

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

  # Position along a wall of `side` (x on north / south walls, y on east / west).
  defp along(rectangle, side) when side in [:north, :south], do: rectangle.x
  defp along(rectangle, _side), do: rectangle.y

  defp length_along(rectangle, side) when side in [:north, :south], do: rectangle.width
  defp length_along(rectangle, _side), do: rectangle.depth

  defp relative(rectangle, {origin_x, origin_y}),
    do: %Rectangle{
      x: rectangle.x - origin_x,
      y: rectangle.y - origin_y,
      width: rectangle.width,
      depth: rectangle.depth
    }

  defp difference({left_x, left_y}, {right_x, right_y}), do: {left_x - right_x, left_y - right_y}

  defp translate(rectangle, delta_x, delta_y),
    do: %{rectangle | x: rectangle.x + delta_x, y: rectangle.y + delta_y}

  defp rectangle(%Rectangle{} = rectangle), do: rectangle

  defp rectangle(%{width: width, depth: depth} = rectangle),
    do: %Rectangle{x: rectangle[:x], y: rectangle[:y], width: width, depth: depth}

  defp find(items, id), do: Enum.find(items, &(&1.id == id))

  defp insert_zone(plan, zone) do
    id = unique_id(zone.name, Enum.map(plan.zones, & &1.id))
    {:ok, %{plan | zones: plan.zones ++ [%{zone | id: id}]}, id}
  end

  defp replace_zone(plan, zone),
    do: %{plan | zones: Enum.map(plan.zones, &if(&1.id == zone.id, do: zone, else: &1))}

  defp update_zone_with(plan, zone_id, function) do
    case Enum.find_index(plan.zones, &(&1.id == zone_id)) do
      nil -> {:error, "unknown zone #{zone_id}"}
      index -> {:ok, %{plan | zones: List.update_at(plan.zones, index, function)}}
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
