defmodule Belgo.Plans.WallPosition do
  @moduledoc """
  Positions along a rectangle wall, shared by anchored rooms (`Belgo.Plans.Anchor`)
  and openings (`Belgo.Plans.Opening`). Pure functions.

  A wall is a side (`:north`, `:south`, `:east`, `:west`) of a rectangle. Its
  `:start` and `:end` are its left and right ends as seen from inside the rectangle,
  facing the wall: the start of the north wall is its west end, of the east wall its
  north end, of the south wall its east end, of the west wall its south end. Something
  `length` long is aligned on the `:start` (`offset` centimetres from the start), on
  the `:end` (`offset` from the end) or centred (`:center`, no offset).
  """

  import Ecto.Changeset

  alias Belgo.Plans.Geometry

  @type side :: :north | :south | :east | :west
  @type align :: :start | :end | :center

  @sides ~w(north south east west)a
  @aligns ~w(start end center)a

  @doc "Lists the sides of a rectangle."
  @spec sides() :: [side()]
  def sides, do: @sides

  @doc "Lists the alignments along a wall."
  @spec aligns() :: [align()]
  def aligns, do: @aligns

  @doc "The side facing `side` (the wall of a neighbour against it)."
  @spec opposite(side()) :: side()
  def opposite(:north), do: :south
  def opposite(:south), do: :north
  def opposite(:west), do: :east
  def opposite(:east), do: :west

  @doc "The segment of a side of a rectangle."
  @spec wall(Geometry.rectangle(), side()) :: Geometry.segment()
  def wall(rectangle, :north),
    do: {:horizontal, rectangle.y, rectangle.x, rectangle.x + rectangle.width}

  def wall(rectangle, :south),
    do: {:horizontal, rectangle.y + rectangle.depth, rectangle.x, rectangle.x + rectangle.width}

  def wall(rectangle, :west),
    do: {:vertical, rectangle.x, rectangle.y, rectangle.y + rectangle.depth}

  def wall(rectangle, :east),
    do: {:vertical, rectangle.x + rectangle.width, rectangle.y, rectangle.y + rectangle.depth}

  @doc """
  The lowest coordinate along the wall (x on north / south walls, y on east / west
  walls) of something `length` long aligned on the `side` wall.
  """
  @spec low_coordinate(Geometry.segment(), side(), align(), integer() | nil, number()) ::
          integer()
  def low_coordinate({_axis, _position, first, last}, _side, :center, _offset, length),
    do: first + div(last - first - round(length), 2)

  def low_coordinate({_axis, _position, first, last}, side, align, offset, length) do
    offset = offset || 0

    if counted_from_low_end?(side, align),
      do: first + offset,
      else: last - offset - round(length)
  end

  @doc """
  The offset placing something `length` long at `low` along the wall with the given
  alignment; `nil` when centred.
  """
  @spec offset_for(Geometry.segment(), side(), align(), integer(), number()) :: integer() | nil
  def offset_for(_wall, _side, :center, _low, _length), do: nil

  def offset_for({_axis, _position, first, last}, side, align, low, length) do
    if counted_from_low_end?(side, align),
      do: low - first,
      else: last - low - round(length)
  end

  @doc "Clears the offset of centred positions, defaults it to 0 otherwise."
  @spec normalize_offset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def normalize_offset(changeset) do
    case get_field(changeset, :align) do
      :center ->
        put_change(changeset, :offset, nil)

      _end ->
        if get_field(changeset, :offset), do: changeset, else: put_change(changeset, :offset, 0)
    end
  end

  # The start of the north and east walls is their low end, of the south and west
  # walls their high end; `:end` is the other one.
  defp counted_from_low_end?(side, :start), do: side in [:north, :east]
  defp counted_from_low_end?(side, :end), do: side in [:south, :west]
end
