defmodule Belgo.Plans.Level do
  @moduledoc """
  A level of a home (basement, ground floor, a garage half a level up…). Its height
  is relative: `offset` levels (`0.5`, `1`…) above its `base_id` level, the level
  without base being the reference. Absolute heights are computed
  (`Belgo.Plans.Analysis`), never stored.
  """

  use Belgo, :schema

  alias Belgo.Inventory.Identifier

  @fields ~w(id name base_id offset)a

  embedded_schema do
    field(:name, :string)
    field(:base_id, :string)
    field(:offset, :float, default: 0.0)
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
  end
end
