defmodule Belgo.Plans.Shape do
  @moduledoc """
  The physical box of a placed device (a rack, a cabinet, a television), in
  centimetres: `width` along the plan's x axis (along its wall for a wall device),
  `depth` along y (out of its wall), `height` upwards. Without a shape a device is
  a point.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Belgo.Plans.Geometry
  alias Belgo.Plans.Placement
  alias Belgo.Plans.Zone

  @type t :: %__MODULE__{}

  @fields ~w(width depth height)a

  @primary_key false
  embedded_schema do
    field(:width, :integer)
    field(:depth, :integer)
    field(:height, :integer)
  end

  @doc "Builds a changeset; every dimension is required and positive."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(shape, params) do
    shape
    |> cast(params, @fields)
    |> validate_required(@fields)
    |> validate_number(:width, greater_than: 0)
    |> validate_number(:depth, greater_than: 0)
    |> validate_number(:height, greater_than: 0)
  end

  @doc """
  The floor rectangle covered by a placed box, in the coordinates of the zone's
  resolved rectangles, or `nil` without shape. A box whose point lies on a wall of
  its zone (a wall device, or a floor / floating one put against a wall) is centred
  along that wall with its back on it, `wall_gap` away from the wall line (half the
  wall thickness touches its inner face), standing into the room; other boxes are
  centred on their point. Walls are axis aligned, so the rectangle is too.
  """
  @spec footprint(Placement.t(), Zone.t(), number()) :: Geometry.rectangle() | nil
  def footprint(placement, zone, wall_gap \\ 0)

  def footprint(%Placement{shape: nil}, _zone, _wall_gap), do: nil

  def footprint(
        %Placement{shape: %__MODULE__{} = shape} = placement,
        %Zone{} = zone,
        wall_gap
      ) do
    walls = Geometry.outline(zone.rectangles)

    case Enum.find(walls, &Geometry.point_on_walls?([&1], placement.x, placement.y)) do
      {:horizontal, wall_y, _first, _last} ->
        %{
          x: placement.x - div(shape.width, 2),
          y: back(inside?(zone, placement.x, wall_y + 1), wall_y, wall_gap, shape.depth),
          width: shape.width,
          depth: shape.depth
        }

      {:vertical, wall_x, _first, _last} ->
        %{
          x: back(inside?(zone, wall_x + 1, placement.y), wall_x, wall_gap, shape.depth),
          y: placement.y - div(shape.width, 2),
          width: shape.depth,
          depth: shape.width
        }

      nil ->
        centred(placement, shape)
    end
  end

  # Where the box starts across its wall: the room is on the positive side, or not.
  defp back(true = _room_after_wall?, wall, wall_gap, _depth), do: wall + wall_gap
  defp back(false, wall, wall_gap, depth), do: wall - wall_gap - depth

  defp centred(placement, shape) do
    %{
      x: placement.x - div(shape.width, 2),
      y: placement.y - div(shape.depth, 2),
      width: shape.width,
      depth: shape.depth
    }
  end

  defp inside?(zone, x, y), do: Geometry.contains_point?(zone.rectangles, x, y)
end
