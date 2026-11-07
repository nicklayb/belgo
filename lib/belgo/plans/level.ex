defmodule Belgo.Plans.Level do
  @moduledoc """
  A level of a home (basement, ground floor, a garage half a level up…). Its height
  is relative: `offset` times the height of its `base_id` level above it, the level
  without base being the reference. Each level has its own `height` (floor to floor)
  and `wall_height`; when absent, the home's `level_height` / `wall_height` apply
  (`Belgo.Plans.Levels`). Absolute heights are computed, never stored.
  """

  use Belgo, :schema

  alias Belgo.Inventory.Identifier

  @fields ~w(id name base_id offset height wall_height)a

  embedded_schema do
    field(:name, :string)
    field(:base_id, :string)
    field(:offset, :float, default: 0.0)
    field(:height, :integer)
    field(:wall_height, :integer)
  end

  @doc "Builds a changeset validating the level on its own."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(level, params) do
    level
    |> cast(params, @fields)
    |> Identifier.put_default(:name)
    |> validate_required([:id, :name, :offset])
    |> Identifier.validate(:id)
    |> Identifier.validate(:base_id)
    |> validate_number(:height, greater_than: 0)
    |> validate_number(:wall_height, greater_than: 0)
  end
end
