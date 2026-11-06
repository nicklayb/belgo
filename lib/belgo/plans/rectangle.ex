defmodule Belgo.Plans.Rectangle do
  @moduledoc """
  A rectangle of a zone, in centimetres: top-left corner (`x`, `y`), `width` along
  x, `depth` along y. The corner is in the zone's frame (`Belgo.Plans.Layout`): the
  first rectangle of an anchored room has no corner (its anchor places it).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          x: integer() | nil,
          y: integer() | nil,
          width: pos_integer(),
          depth: pos_integer()
        }

  @fields ~w(x y width depth)a

  @primary_key false
  embedded_schema do
    field(:x, :integer)
    field(:y, :integer)
    field(:width, :integer)
    field(:depth, :integer)
  end

  @doc "Builds a changeset; sizes must be positive (the zone checks the corner)."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rectangle, params) do
    rectangle
    |> cast(params, @fields)
    |> validate_required([:width, :depth])
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:depth, greater_than: 0)
  end
end
