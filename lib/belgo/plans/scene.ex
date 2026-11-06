defmodule Belgo.Plans.Scene do
  @moduledoc """
  What the 3D view draws, computed from a plan and its analysis (never stored), in
  centimetres with the plan axes: `x` and `y` on the floor, `elevation` upwards.
  The browser only turns it into meshes. Pure functions.

    * floors: one per zone rectangle at its level height; exterior zones at the
      ground height, cut around the home's footprint (the ground is never seen inside
      rooms); orphan rooms are left out
    * walls: the walls of each level split around doors and openings, with a lintel
      above each (doors and openings stop below the wall top)
    * devices: a point per placement (floor, wall at its height, floating)
  """

  alias Belgo.Inventory.Snapshot
  alias Belgo.Plans.Analysis
  alias Belgo.Plans.Geometry
  alias Belgo.Plans.Opening
  alias Belgo.Plans.Plan
  alias Belgo.Plans.Zone

  @opening_height_centimetres 210
  @minimum_lintel_centimetres 20
  @wall_thickness_centimetres 10

  @type wall_piece :: %{
          x1: number(),
          y1: number(),
          x2: number(),
          y2: number(),
          bottom: number(),
          top: number(),
          kind: :wall | :lintel | :door
        }

  @doc "The scene of a plan, as plain maps ready to be sent to the browser."
  @spec build(Plan.t(), Analysis.t(), Snapshot.t()) :: map()
  def build(%Plan{} = plan, %Analysis{} = analysis, %Snapshot{} = snapshot) do
    zone_by_id = Map.new(plan.zones, &{&1.id, &1})
    device_by_id = Snapshot.index(snapshot, :devices)
    visible_zones = Enum.reject(plan.zones, &(&1.id in analysis.orphan_zone_ids))

    %{
      wall_height: plan.wall_height,
      wall_thickness: @wall_thickness_centimetres,
      ground_elevation: analysis.ground_elevation,
      levels:
        plan.levels
        |> Enum.map(
          &%{id: &1.id, name: &1.name, elevation: Map.get(analysis.elevations, &1.id, 0.0)}
        )
        |> Enum.sort_by(& &1.elevation),
      floors: Enum.flat_map(visible_zones, &floors(&1, plan, analysis, footprint(visible_zones))),
      walls: walls(plan, analysis),
      devices:
        plan.placements
        |> Enum.filter(
          &(Map.has_key?(zone_by_id, &1.zone_id) and &1.zone_id not in analysis.orphan_zone_ids)
        )
        |> Enum.map(&device(&1, zone_by_id[&1.zone_id], device_by_id, analysis))
    }
  end

  @doc """
  Splits a wall segment around the openings lying on it: full height pieces between
  them, and for each opening a lintel from the opening height to the wall top (doors
  also get a door piece).
  """
  @spec split_wall(tuple(), [Opening.t()], number(), number()) :: [wall_piece()]
  def split_wall({axis, position, first, last}, openings, bottom, wall_height) do
    top = bottom + wall_height

    opening_top =
      bottom + min(@opening_height_centimetres, wall_height - @minimum_lintel_centimetres)

    spans =
      openings
      |> Enum.map(&{Opening.segment(&1), &1.kind})
      |> Enum.filter(fn {{opening_axis, opening_position, opening_first, opening_last}, _kind} ->
        opening_axis == axis and opening_position == position and opening_first >= first and
          opening_last <= last
      end)
      |> Enum.map(fn {{_axis, _position, opening_first, opening_last}, kind} ->
        {opening_first, opening_last, kind}
      end)
      |> Enum.sort()

    {pieces, cursor} =
      Enum.reduce(spans, {[], first}, fn {opening_first, opening_last, kind}, {pieces, cursor} ->
        solid =
          if opening_first > cursor,
            do: [piece(axis, position, cursor, opening_first, bottom, top, :wall)],
            else: []

        lintel = [piece(axis, position, opening_first, opening_last, opening_top, top, :lintel)]

        door =
          if kind == :door,
            do: [piece(axis, position, opening_first, opening_last, bottom, opening_top, :door)],
            else: []

        {pieces ++ solid ++ lintel ++ door, max(cursor, opening_last)}
      end)

    rest =
      if last > cursor, do: [piece(axis, position, cursor, last, bottom, top, :wall)], else: []

    pieces ++ rest
  end

  defp piece(:horizontal, y, first, last, bottom, top, kind),
    do: %{x1: first, y1: y, x2: last, y2: y, bottom: bottom, top: top, kind: kind}

  defp piece(:vertical, x, first, last, bottom, top, kind),
    do: %{x1: x, y1: first, x2: x, y2: last, bottom: bottom, top: top, kind: kind}

  defp footprint(zones),
    do: for(zone <- zones, not Zone.exterior?(zone), rectangle <- zone.rectangles, do: rectangle)

  defp floors(zone, plan, analysis, footprint) do
    elevation = zone_elevation(zone, analysis)

    rectangles =
      if Zone.exterior?(zone),
        do: Enum.flat_map(zone.rectangles, &Geometry.subtract_rectangles(&1, footprint)),
        else: zone.rectangles

    Enum.map(rectangles, fn rectangle ->
      %{
        zone_id: zone.id,
        name: zone.name,
        level_id: zone.level_id,
        exterior: Zone.exterior?(zone),
        x: rectangle.x,
        y: rectangle.y,
        width: rectangle.width,
        depth: rectangle.depth,
        elevation: elevation,
        top: if(Zone.exterior?(zone), do: elevation, else: elevation + plan.wall_height)
      }
    end)
  end

  defp walls(plan, analysis) do
    hidden = MapSet.new(analysis.orphan_zone_ids)

    visible_walls =
      plan.zones
      |> Enum.reject(&(Zone.exterior?(&1) or MapSet.member?(hidden, &1.id)))
      |> Enum.group_by(& &1.level_id)
      |> Map.new(fn {level_id, zones} ->
        {level_id,
         Belgo.Plans.Geometry.merge(
           Enum.flat_map(zones, &Belgo.Plans.Geometry.outline(&1.rectangles))
         )}
      end)

    Enum.flat_map(visible_walls, fn {level_id, segments} ->
      bottom = Map.get(analysis.elevations, level_id, 0.0)
      openings = Enum.filter(plan.openings, &(&1.level_id == level_id))

      segments
      |> Enum.flat_map(&split_wall(&1, openings, bottom, plan.wall_height))
      |> Enum.map(&Map.put(&1, :level_id, level_id))
    end)
  end

  defp device(placement, zone, device_by_id, analysis) do
    device = Map.get(device_by_id, placement.device_id)

    %{
      device_id: placement.device_id,
      name: (device && device.name) || placement.device_id,
      known: device != nil,
      level_id: zone.level_id,
      anchor: placement.anchor,
      x: placement.x,
      y: placement.y,
      elevation: zone_elevation(zone, analysis) + placement.height
    }
  end

  defp zone_elevation(%Zone{level_id: nil}, analysis), do: analysis.ground_elevation

  defp zone_elevation(%Zone{level_id: level_id}, analysis),
    do: Map.get(analysis.elevations, level_id, 0.0)
end
