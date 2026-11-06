defmodule Belgo.Plans.Anchor do
  @moduledoc """
  How a room sticks to another one of its level: its first rectangle lies against
  the `side` wall of the parent's (`zone_id`) rectangle at index `rectangle` (`nil`:
  the first one), on the
  outer side of that wall. Along the wall it is placed like an opening
  (`Belgo.Plans.WallPosition`): `align` `:start` / `:end` with `offset` centimetres
  from that end of the wall, or `:center` (no offset). Only these relations are
  stored; positions are computed by `Belgo.Plans.Layout`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Belgo.Inventory.Identifier
  alias Belgo.Plans.WallPosition

  @type t :: %__MODULE__{
          zone_id: String.t(),
          rectangle: non_neg_integer() | nil,
          side: WallPosition.side(),
          align: WallPosition.align(),
          offset: integer() | nil
        }

  @fields ~w(zone_id rectangle side align offset)a

  @primary_key false
  embedded_schema do
    field(:zone_id, :string)
    # Index of the rectangle in its zone; `nil` is the first one (kept out of files).
    field(:rectangle, :integer)
    field(:side, Ecto.Enum, values: WallPosition.sides())
    field(:align, Ecto.Enum, values: WallPosition.aligns(), default: :start)
    field(:offset, :integer)
  end

  @doc "Builds a changeset: a parent, a side, an alignment (offset unused when centred)."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(anchor, params) do
    anchor
    |> cast(params, @fields)
    |> validate_required([:zone_id, :side, :align])
    |> Identifier.validate(:zone_id)
    |> validate_number(:rectangle, greater_than_or_equal_to: 0)
    |> WallPosition.normalize_offset()
  end
end
