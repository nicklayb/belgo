defmodule Belgo.Plans.Opening do
  @moduledoc """
  A door or an opening in a room wall: the `side` wall of the rectangle at index
  `rectangle` (`nil`: the first one) of the zone `zone_id`, `width` centimetres wide, placed along that wall
  by `align` and `offset` (`Belgo.Plans.WallPosition`: "150 cm wide, 50 cm from the
  left of the wall" is `align: start, offset: 50, width: 150`; centred has no
  offset). It follows its room. Stored once even on a wall shared by two rooms. In
  3D, a lintel stays above it.

  `level_id`, `x`, `y` (start of the opening) and `axis` (`:horizontal` towards x,
  `:vertical` towards y) are its absolute position: computed by `Belgo.Plans.Layout`
  for wall openings, stored only by the former absolute format (an opening without
  `zone_id`), which `Belgo.Plans.Plan` turns into wall openings when a room wall
  holds it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Belgo.Inventory.Identifier
  alias Belgo.Plans.Geometry
  alias Belgo.Plans.WallPosition

  @type t :: %__MODULE__{}

  @kinds ~w(door opening)a
  @axes ~w(horizontal vertical)a
  @wall_fields ~w(zone_id rectangle side align offset)a
  @absolute_fields ~w(level_id x y axis)a

  @primary_key false
  embedded_schema do
    field(:zone_id, :string)
    # Index of the rectangle in its zone; `nil` is the first one (kept out of files).
    field(:rectangle, :integer)
    field(:side, Ecto.Enum, values: WallPosition.sides())
    field(:align, Ecto.Enum, values: WallPosition.aligns())
    field(:offset, :integer)
    field(:width, :integer)
    field(:kind, Ecto.Enum, values: @kinds, default: :door)
    field(:level_id, :string)
    field(:x, :integer)
    field(:y, :integer)
    field(:axis, Ecto.Enum, values: @axes)
  end

  @doc "Lists the kinds of openings."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Returns `true` for an opening on a room wall (`false`: the former absolute format)."
  @spec on_wall?(t()) :: boolean()
  def on_wall?(%__MODULE__{zone_id: zone_id}), do: zone_id != nil

  @doc "The wall segment the opening occupies, `nil` when its position is unknown."
  @spec segment(t()) :: Geometry.segment() | nil
  def segment(%__MODULE__{axis: :horizontal} = opening),
    do: {:horizontal, opening.y, opening.x, opening.x + opening.width}

  def segment(%__MODULE__{axis: :vertical} = opening),
    do: {:vertical, opening.x, opening.y, opening.y + opening.width}

  def segment(%__MODULE__{}), do: nil

  @doc "Removes the computed absolute position of a wall opening, keeping what is stored."
  @spec stored(t()) :: t()
  def stored(%__MODULE__{zone_id: nil} = opening), do: opening

  def stored(%__MODULE__{} = opening),
    do: %{opening | level_id: nil, x: nil, y: nil, axis: nil}

  @doc """
  Builds a changeset: a wall opening needs its room, side and alignment (its
  absolute position is dropped), a former absolute one its level and position.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(opening, params) do
    changeset =
      opening
      |> cast(params, @wall_fields ++ @absolute_fields ++ [:width, :kind])
      |> validate_required([:width, :kind])
      |> validate_number(:width, greater_than: 0)

    if get_field(changeset, :zone_id) do
      changeset
      |> validate_required([:zone_id, :side])
      |> put_default_align()
      |> Identifier.validate(:zone_id)
      |> validate_number(:rectangle, greater_than_or_equal_to: 0)
      |> WallPosition.normalize_offset()
      |> clear_absolute_position()
    else
      changeset
      |> validate_required(@absolute_fields)
      |> Identifier.validate(:level_id)
    end
  end

  defp put_default_align(changeset) do
    if get_field(changeset, :align), do: changeset, else: put_change(changeset, :align, :start)
  end

  defp clear_absolute_position(changeset),
    do: Enum.reduce(@absolute_fields, changeset, &put_change(&2, &1, nil))
end
