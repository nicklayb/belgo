defmodule Belgo.Plans.Opening do
  @moduledoc """
  A door or an opening in a wall of a level: from (`x`, `y`) along `axis`
  (`:horizontal` towards x, `:vertical` towards y) over `width` centimetres. Stored
  once even on a wall shared by two rooms. In 3D, a lintel stays above it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Belgo.Inventory.Identifier
  alias Belgo.Plans.Geometry

  @type t :: %__MODULE__{}

  @kinds ~w(door opening)a
  @axes ~w(horizontal vertical)a
  @fields ~w(level_id x y axis width kind)a

  @primary_key false
  embedded_schema do
    field(:level_id, :string)
    field(:x, :integer)
    field(:y, :integer)
    field(:axis, Ecto.Enum, values: @axes)
    field(:width, :integer)
    field(:kind, Ecto.Enum, values: @kinds, default: :door)
  end

  @doc "Lists the kinds of openings."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "The wall segment the opening occupies."
  @spec segment(t()) :: Geometry.segment()
  def segment(%__MODULE__{axis: :horizontal} = opening),
    do: {:horizontal, opening.y, opening.x, opening.x + opening.width}

  def segment(%__MODULE__{axis: :vertical} = opening),
    do: {:vertical, opening.x, opening.y, opening.y + opening.width}

  @doc "Builds a changeset validating the opening on its own."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(opening, params) do
    opening
    |> cast(params, @fields)
    |> validate_required(@fields)
    |> Identifier.validate(:level_id)
    |> validate_number(:width, greater_than: 0)
  end
end
