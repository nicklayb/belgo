defmodule Belgo.Plans.Zone do
  @moduledoc """
  A zone of a plan: a room on a level (`level_id`), walled on its outline, or an
  exterior zone at ground level (no `level_id`, no walls). Made of touching,
  non-overlapping rectangles, so L-shaped rooms are one zone. `location_id` links it
  to an inventory location (the location never refers to the plan).
  """

  use Belgo, :schema

  alias Belgo.Inventory.Identifier
  alias Belgo.Plans.Geometry
  alias Belgo.Plans.Rectangle

  @fields ~w(id name level_id location_id)a

  embedded_schema do
    field(:name, :string)
    field(:level_id, :string)
    field(:location_id, :string)
    embeds_many(:rectangles, Rectangle, on_replace: :delete)
  end

  @doc "Returns `true` for exterior zones (at ground level, without walls)."
  @spec exterior?(t()) :: boolean()
  def exterior?(%__MODULE__{level_id: level_id}), do: is_nil(level_id)

  @doc "Builds a changeset: at least one rectangle, all touching, none overlapping."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(zone, params) do
    zone
    |> cast(params, @fields)
    |> cast_embed(:rectangles, required: true)
    |> Identifier.put_default(:name)
    |> validate_required([:id, :name])
    |> Identifier.validate(:id)
    |> Identifier.validate(:level_id)
    |> Identifier.validate(:location_id)
    |> validate_shape()
  end

  defp validate_shape(changeset) do
    rectangles = get_field(changeset, :rectangles)

    cond do
      overlapping?(rectangles) ->
        add_error(changeset, :rectangles, "must not overlap")

      not Geometry.connected?(rectangles) ->
        add_error(changeset, :rectangles, "must touch each other")

      true ->
        changeset
    end
  end

  defp overlapping?(rectangles) do
    for {left_rectangle, position} <- Enum.with_index(rectangles),
        right_rectangle <- Enum.drop(rectangles, position + 1),
        reduce: false do
      found -> found or Geometry.overlap?(left_rectangle, right_rectangle)
    end
  end
end
