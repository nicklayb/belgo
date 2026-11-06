defmodule Belgo.Plans.Zone do
  @moduledoc """
  A zone of a plan: a room on a level (`level_id`), walled on its outline, or an
  exterior zone at ground level (no `level_id`, no walls). Made of touching,
  non-overlapping rectangles, so L-shaped rooms are one zone. `location_id` links it
  to an inventory location (the location never refers to the plan).

  A zone is either a root, its rectangles at absolute positions, or `anchor`ed to
  another zone of its level (`Belgo.Plans.Anchor`): its first rectangle has only a
  size (the anchor places it), the others are positioned relative to the first
  one's top-left corner (`Belgo.Plans.Layout`).
  """

  use Belgo, :schema

  alias Belgo.Inventory.Identifier
  alias Belgo.Plans.Anchor
  alias Belgo.Plans.Geometry
  alias Belgo.Plans.Rectangle

  @fields ~w(id name level_id location_id)a

  embedded_schema do
    field(:name, :string)
    field(:level_id, :string)
    field(:location_id, :string)
    embeds_one(:anchor, Anchor, on_replace: :update)
    embeds_many(:rectangles, Rectangle, on_replace: :delete)
  end

  @doc "Returns `true` for exterior zones (at ground level, without walls)."
  @spec exterior?(t()) :: boolean()
  def exterior?(%__MODULE__{level_id: level_id}), do: is_nil(level_id)

  @doc "Returns `true` when the zone is positioned by an anchor to another zone."
  @spec anchored?(t()) :: boolean()
  def anchored?(%__MODULE__{anchor: anchor}), do: anchor != nil

  @doc """
  The rectangles in the zone's own frame: those of a root as stored, those of an
  anchored zone with its first rectangle at (0, 0).
  """
  @spec frame_rectangles(t()) :: [Rectangle.t()]
  def frame_rectangles(%__MODULE__{anchor: nil, rectangles: rectangles}), do: rectangles

  def frame_rectangles(%__MODULE__{rectangles: [first | rest]}),
    do: [%{first | x: 0, y: 0} | rest]

  def frame_rectangles(%__MODULE__{rectangles: []}), do: []

  @doc """
  Builds a changeset: at least one rectangle, all positioned (except the first one of
  an anchored zone), touching, none overlapping.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(zone, params) do
    zone
    |> cast(params, @fields)
    |> cast_embed(:anchor)
    |> cast_embed(:rectangles, required: true)
    |> Identifier.put_default(:name)
    |> validate_required([:id, :name])
    |> Identifier.validate(:id)
    |> Identifier.validate(:level_id)
    |> Identifier.validate(:location_id)
    |> validate_shape()
  end

  defp validate_shape(changeset) do
    zone = %__MODULE__{
      anchor: get_field(changeset, :anchor),
      rectangles: get_field(changeset, :rectangles)
    }

    rectangles = frame_rectangles(zone)

    cond do
      anchored?(zone) and positioned_first?(zone) ->
        add_error(
          changeset,
          :rectangles,
          "the first rectangle of an anchored room has no x / y (its anchor places it)"
        )

      Enum.any?(rectangles, &(is_nil(&1.x) or is_nil(&1.y))) ->
        add_error(changeset, :rectangles, "need x and y")

      overlapping?(rectangles) ->
        add_error(changeset, :rectangles, "must not overlap")

      not Geometry.connected?(rectangles) ->
        add_error(changeset, :rectangles, "must touch each other")

      true ->
        changeset
    end
  end

  defp positioned_first?(%__MODULE__{rectangles: [first | _rest]}),
    do: first.x != nil or first.y != nil

  defp positioned_first?(_zone), do: false

  defp overlapping?(rectangles) do
    for {left_rectangle, position} <- Enum.with_index(rectangles),
        right_rectangle <- Enum.drop(rectangles, position + 1),
        reduce: false do
      found -> found or Geometry.overlap?(left_rectangle, right_rectangle)
    end
  end
end
