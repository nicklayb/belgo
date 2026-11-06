defmodule Belgo.Plans.Rectangle do
  @moduledoc "A rectangle of a zone, in centimetres: top-left corner (`x`, `y`), `width` along x, `depth` along y."

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{x: integer(), y: integer(), width: pos_integer(), depth: pos_integer()}

  @fields ~w(x y width depth)a

  @primary_key false
  embedded_schema do
    field(:x, :integer)
    field(:y, :integer)
    field(:width, :integer)
    field(:depth, :integer)
  end

  @doc "Builds a changeset; sizes must be positive."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(rectangle, params) do
    rectangle
    |> cast(params, @fields)
    |> validate_required(@fields)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:depth, greater_than: 0)
  end
end
