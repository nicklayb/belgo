defmodule Belgo.Plans.Placement do
  @moduledoc """
  Where an inventory device is on the plan: in a zone, anchored to the `:floor`, to a
  `:wall` (the point lies on a wall, at `height`) or `:float`ing at `height`, in
  centimetres from the zone floor. An optional `shape` gives the device a box whose
  footprint is centred on the point (out of the wall when the point is on one) and whose
  bottom is at `height`. The device never refers to the plan.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Belgo.Inventory.Identifier
  alias Belgo.Plans.Shape

  @type t :: %__MODULE__{}

  @anchors ~w(floor wall float)a
  @fields ~w(device_id zone_id anchor x y height)a
  @default_wall_height_centimetres 150

  @primary_key false
  embedded_schema do
    field(:device_id, :string)
    field(:zone_id, :string)
    field(:anchor, Ecto.Enum, values: @anchors, default: :floor)
    field(:x, :integer)
    field(:y, :integer)
    field(:height, :integer, default: 0)
    embeds_one(:shape, Shape, on_replace: :update)
  end

  @doc "Lists the anchors."
  @spec anchors() :: [atom()]
  def anchors, do: @anchors

  @doc "Height given to devices put on a wall without one."
  @spec default_wall_height() :: pos_integer()
  def default_wall_height, do: @default_wall_height_centimetres

  @doc "Builds a changeset validating the placement on its own."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(placement, params) do
    placement
    |> cast(params, @fields)
    |> cast_embed(:shape)
    |> validate_required(~w(device_id zone_id anchor x y height)a)
    |> Identifier.validate(:device_id)
    |> Identifier.validate(:zone_id)
    |> validate_number(:height, greater_than_or_equal_to: 0)
  end
end
