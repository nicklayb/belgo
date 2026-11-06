defmodule Belgo.Plans.Ground do
  @moduledoc "The outside ground level: `percent` of the height of a level (`80` of the basement)."

  use Ecto.Schema

  import Ecto.Changeset

  alias Belgo.Inventory.Identifier

  @type t :: %__MODULE__{}

  @maximum_percent 100

  @primary_key false
  embedded_schema do
    field(:level_id, :string)
    field(:percent, :integer, default: 0)
  end

  @doc "Builds a changeset; the percentage goes from 0 to 100."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(ground, params) do
    ground
    |> cast(params, [:level_id, :percent])
    |> validate_required([:level_id, :percent])
    |> Identifier.validate(:level_id)
    |> validate_number(:percent,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @maximum_percent
    )
  end
end
