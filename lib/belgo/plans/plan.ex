defmodule Belgo.Plans.Plan do
  @moduledoc """
  The 3D plan of one home, in `plans.yaml`: its levels, zones (rooms and exterior),
  doors and openings, the ground level and where devices are. Only what is drawn is
  stored; heights, walls, measures and warnings are computed
  (`Belgo.Plans.Analysis`). Distances are in centimetres. Inventory records are
  referenced (`location_id`, `device_id`), never the other way around.

  The changeset checks the plan on its own: unique identifiers, known levels and
  zones, levels without cycle, anchors resolvable (`Belgo.Plans.Layout`), zones of a
  level not overlapping once laid out, one placement per device. Openings in the
  former absolute format (`level_id`, `x`, `y`, `axis`) are put on the room wall
  holding them, when one does. Links to the inventory are checked by the analysis (a deleted device stays
  on the plan with a warning).
  """

  use Belgo, :schema

  alias Belgo.Inventory.Identifier
  alias Belgo.Plans.Geometry
  alias Belgo.Plans.Ground
  alias Belgo.Plans.Layout
  alias Belgo.Plans.Level
  alias Belgo.Plans.Levels
  alias Belgo.Plans.Opening
  alias Belgo.Plans.Placement
  alias Belgo.Plans.Zone

  @default_wall_height_centimetres 250
  @default_level_height_centimetres 270
  @fields ~w(id name location_id wall_height level_height)a

  embedded_schema do
    field(:name, :string)
    field(:location_id, :string)
    field(:wall_height, :integer, default: @default_wall_height_centimetres)
    field(:level_height, :integer, default: @default_level_height_centimetres)
    # Set on the computed copy of `Belgo.Plans.Layout.resolve/1`, never stored.
    field(:resolved, :boolean, virtual: true, default: false)
    embeds_one(:ground, Ground, on_replace: :update)
    embeds_many(:levels, Level, on_replace: :delete)
    embeds_many(:zones, Zone, on_replace: :delete)
    embeds_many(:openings, Opening, on_replace: :delete)
    embeds_many(:placements, Placement, on_replace: :delete)
  end

  @doc "Builds a changeset validating the plan on its own."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(plan, params) do
    plan
    |> cast(params, @fields)
    |> cast_embed(:ground)
    |> cast_embed(:levels)
    |> cast_embed(:zones)
    |> cast_embed(:openings)
    |> cast_embed(:placements)
    |> Identifier.put_default(:name)
    |> validate_required([:id, :name, :wall_height, :level_height])
    |> Identifier.validate(:id)
    |> Identifier.validate(:location_id)
    |> validate_number(:wall_height, greater_than: 0)
    |> validate_number(:level_height, greater_than: 0)
    |> validate_unique(:levels, & &1.id, "level")
    |> validate_unique(:zones, & &1.id, "zone")
    |> validate_unique(:placements, & &1.device_id, "placement of device")
    |> validate_levels()
    |> validate_references()
    |> validate_anchors()
    |> validate_zones_apart()
    |> attach_absolute_openings()
  end

  defp current_plan(changeset) do
    %__MODULE__{
      zones: get_field(changeset, :zones),
      openings: get_field(changeset, :openings),
      placements: get_field(changeset, :placements)
    }
  end

  defp validate_anchors(changeset) do
    changeset
    |> current_plan()
    |> Layout.errors()
    |> Enum.reduce(changeset, fn {_zone_id, message}, accumulator ->
      add_error(accumulator, :zones, message)
    end)
  end

  # Openings of the former absolute format move onto the room wall holding them.
  defp attach_absolute_openings(changeset) do
    openings = get_field(changeset, :openings)

    if changeset.valid? and Enum.any?(openings, &(not Opening.on_wall?(&1))) do
      resolved = Layout.resolve(current_plan(changeset))
      put_embed(changeset, :openings, Enum.map(openings, &attach_opening(&1, resolved)))
    else
      changeset
    end
  end

  defp attach_opening(%Opening{zone_id: nil} = opening, resolved) do
    {_axis, _position, first, _last} = segment = Opening.segment(opening)

    case Layout.walls_containing(resolved, opening.level_id, segment) do
      [{zone, index, side} | _others] -> Layout.put_on_wall(opening, zone, index, side, first)
      [] -> opening
    end
  end

  defp attach_opening(opening, _resolved), do: opening

  defp validate_unique(changeset, field, key, label) do
    duplicates =
      changeset
      |> get_field(field)
      |> Enum.frequencies_by(key)
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> Enum.map(fn {duplicate, _count} -> duplicate end)

    Enum.reduce(duplicates, changeset, &add_error(&2, field, "#{label} #{&1} is defined twice"))
  end

  defp validate_levels(changeset) do
    case Levels.elevations(get_field(changeset, :levels), get_field(changeset, :level_height)) do
      {:ok, _elevations} ->
        changeset

      {:error, invalid} ->
        add_error(
          changeset,
          :levels,
          "unknown or cyclic base for #{Enum.join(invalid, ", ")}"
        )
    end
  end

  defp validate_references(changeset) do
    level_ids = MapSet.new(get_field(changeset, :levels), & &1.id)
    zone_ids = MapSet.new(get_field(changeset, :zones), & &1.id)
    ground = get_field(changeset, :ground)

    errors =
      for(
        %Zone{level_id: level_id} = zone <- get_field(changeset, :zones),
        level_id != nil and not MapSet.member?(level_ids, level_id),
        do: {:zones, "#{zone.name}: unknown level #{level_id}"}
      ) ++
        for(
          %Opening{zone_id: nil, level_id: level_id} <- get_field(changeset, :openings),
          not MapSet.member?(level_ids, level_id),
          do: {:openings, "unknown level #{level_id}"}
        ) ++
        for(
          %Opening{zone_id: zone_id} when zone_id != nil <- get_field(changeset, :openings),
          not MapSet.member?(zone_ids, zone_id),
          do: {:openings, "unknown zone #{zone_id}"}
        ) ++
        for(
          %Placement{zone_id: zone_id} = placement <- get_field(changeset, :placements),
          not MapSet.member?(zone_ids, zone_id),
          do: {:placements, "#{placement.device_id}: unknown zone #{zone_id}"}
        ) ++
        if(ground && not MapSet.member?(level_ids, ground.level_id),
          do: [{:ground, "unknown level #{ground.level_id}"}],
          else: []
        )

    Enum.reduce(errors, changeset, fn {field, message}, accumulator ->
      add_error(accumulator, field, message)
    end)
  end

  # Zones never overlap within a level (rooms) nor at ground level (exterior), once
  # laid out. Zones without position (reported by their own changeset) are left out.
  defp validate_zones_apart(changeset) do
    plan = current_plan(changeset)

    zones_by_level =
      if Enum.all?(plan.zones, &positioned?/1),
        do: Enum.group_by(Layout.resolve(plan).zones, & &1.level_id),
        else: %{}

    overlaps =
      Enum.flat_map(zones_by_level, fn {_level_id, zones} -> overlapping_pairs(zones) end)

    Enum.reduce(overlaps, changeset, fn {left_zone, right_zone}, accumulator ->
      add_error(accumulator, :zones, "#{left_zone.name} and #{right_zone.name} overlap")
    end)
  end

  defp positioned?(zone),
    do: Enum.all?(Zone.frame_rectangles(zone), &(&1.x != nil and &1.y != nil))

  defp overlapping_pairs(zones) do
    for {left_zone, position} <- Enum.with_index(zones),
        right_zone <- Enum.drop(zones, position + 1),
        Enum.any?(left_zone.rectangles, fn left_rectangle ->
          Enum.any?(right_zone.rectangles, &Geometry.overlap?(left_rectangle, &1))
        end),
        do: {left_zone, right_zone}
  end
end
