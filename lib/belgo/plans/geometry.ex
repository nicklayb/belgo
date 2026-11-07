defmodule Belgo.Plans.Geometry do
  @moduledoc """
  Plane geometry of plans: axis-aligned rectangles in centimetres (`x`, `y` of the
  top-left corner, `width` along x, `depth` along y) and the wall segments around
  them. Pure functions.

  A segment is `{:horizontal, y, x1, x2}` or `{:vertical, x, y1, y2}` with
  `x1 < x2` / `y1 < y2`. A zone made of several touching rectangles (an L-shaped
  room) has walls only on its outline: edges shared between its rectangles are not
  walls. Walls of a level are the outlines of its zones merged, so a wall between
  two rooms exists once.
  """

  @type rectangle :: %{x: integer(), y: integer(), width: pos_integer(), depth: pos_integer()}
  @type segment ::
          {:horizontal, integer(), integer(), integer()}
          | {:vertical, integer(), integer(), integer()}

  @doc "Returns `true` when two rectangles share a surface (touching edges do not count)."
  @spec overlap?(rectangle(), rectangle()) :: boolean()
  def overlap?(left_rectangle, right_rectangle) do
    left_rectangle.x < right_rectangle.x + right_rectangle.width and
      right_rectangle.x < left_rectangle.x + left_rectangle.width and
      left_rectangle.y < right_rectangle.y + right_rectangle.depth and
      right_rectangle.y < left_rectangle.y + left_rectangle.depth
  end

  @doc "Returns `true` when two rectangles share an edge of positive length, without overlapping."
  @spec touch?(rectangle(), rectangle()) :: boolean()
  def touch?(left_rectangle, right_rectangle) do
    not overlap?(left_rectangle, right_rectangle) and
      Enum.any?(edges(left_rectangle), fn left_edge ->
        Enum.any?(edges(right_rectangle), &(shared_length(left_edge, &1) > 0))
      end)
  end

  @doc "Returns `true` when every rectangle is reachable from the first one through shared edges."
  @spec connected?([rectangle()]) :: boolean()
  def connected?([]), do: true

  def connected?([first | _rest] = rectangles) do
    length(component(rectangles, [first], [first])) == length(rectangles)
  end

  @doc "Total surface in square centimetres (rectangles of a zone never overlap)."
  @spec area([rectangle()]) :: non_neg_integer()
  def area(rectangles), do: Enum.sum(Enum.map(rectangles, &(&1.width * &1.depth)))

  @doc "Smallest rectangle containing every rectangle, `nil` for none."
  @spec bounds([rectangle()]) :: rectangle() | nil
  def bounds([]), do: nil

  def bounds(rectangles) do
    left = Enum.min(Enum.map(rectangles, & &1.x))
    top = Enum.min(Enum.map(rectangles, & &1.y))
    right = Enum.max(Enum.map(rectangles, &(&1.x + &1.width)))
    bottom = Enum.max(Enum.map(rectangles, &(&1.y + &1.depth)))
    %{x: left, y: top, width: right - left, depth: bottom - top}
  end

  @doc """
  The parts of `rectangle` not covered by `holes`, as rectangles: the plane is cut
  along every hole edge, uncovered cells are kept and merged along rows.
  """
  @spec subtract_rectangles(rectangle(), [rectangle()]) :: [rectangle()]
  def subtract_rectangles(rectangle, holes) do
    holes = Enum.filter(holes, &overlap?(rectangle, &1))
    right = rectangle.x + rectangle.width
    bottom = rectangle.y + rectangle.depth

    xs = cuts(rectangle.x, right, Enum.flat_map(holes, &[&1.x, &1.x + &1.width]))
    ys = cuts(rectangle.y, bottom, Enum.flat_map(holes, &[&1.y, &1.y + &1.depth]))

    for {top, lower} <- Enum.zip(ys, tl(ys)),
        row = row_cells(xs, top, lower, holes),
        cell <- merge_row(row),
        do: cell
  end

  defp cuts(first, last, positions) do
    [first, last | Enum.filter(positions, &(&1 > first and &1 < last))]
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp row_cells(xs, top, lower, holes) do
    for {left, right} <- Enum.zip(xs, tl(xs)),
        cell = %{x: left, y: top, width: right - left, depth: lower - top},
        not Enum.any?(holes, &overlap?(cell, &1)),
        do: cell
  end

  defp merge_row(cells) do
    cells
    |> Enum.reduce([], fn
      cell, [previous | merged] when previous.x + previous.width == cell.x ->
        [%{previous | width: previous.width + cell.width} | merged]

      cell, merged ->
        [cell | merged]
    end)
    |> Enum.reverse()
  end

  @doc "Returns `true` when the point lies in one of the rectangles (edges included)."
  @spec contains_point?([rectangle()], number(), number()) :: boolean()
  def contains_point?(rectangles, x, y) do
    Enum.any?(rectangles, fn rectangle ->
      x >= rectangle.x and x <= rectangle.x + rectangle.width and y >= rectangle.y and
        y <= rectangle.y + rectangle.depth
    end)
  end

  @doc "Outline of a zone: the edges of its rectangles minus the parts they share."
  @spec outline([rectangle()]) :: [segment()]
  def outline(rectangles) do
    all_edges = Enum.flat_map(rectangles, &edges/1)

    rectangles
    |> Enum.flat_map(&edges/1)
    |> Enum.flat_map(fn edge ->
      shared =
        for other <- all_edges, other != edge, opposite?(edge, other), do: interval(other)

      edge
      |> interval()
      |> subtract(shared)
      |> Enum.map(&with_interval(edge, &1))
    end)
    |> merge()
  end

  @doc "Merges segments lying on the same line and overlapping or touching."
  @spec merge([segment()]) :: [segment()]
  def merge(segments) do
    segments
    |> Enum.group_by(fn {axis, position, _start, _end} -> {axis, position} end)
    |> Enum.flat_map(fn {{axis, position}, line_segments} ->
      line_segments
      |> Enum.map(fn {_axis, _position, first, last} -> {first, last} end)
      |> union()
      |> Enum.map(fn {first, last} -> {axis, position, first, last} end)
    end)
    |> Enum.sort()
  end

  @doc "Returns `true` when the segment lies entirely on one of the walls."
  @spec on_walls?([segment()], segment()) :: boolean()
  def on_walls?(walls, {axis, position, first, last}) do
    Enum.any?(walls, fn {wall_axis, wall_position, wall_first, wall_last} ->
      wall_axis == axis and wall_position == position and wall_first <= first and
        last <= wall_last
    end)
  end

  @doc "Returns `true` when the point lies on one of the walls."
  @spec point_on_walls?([segment()], number(), number()) :: boolean()
  def point_on_walls?(walls, x, y) do
    Enum.any?(walls, fn
      {:horizontal, wall_y, first, last} -> y == wall_y and first <= x and x <= last
      {:vertical, wall_x, first, last} -> x == wall_x and first <= y and y <= last
    end)
  end

  @doc """
  Splits segments by the walls lying on the same lines: `{covered, uncovered}`, the
  parts lying on one of the walls and the others.
  """
  @spec partition([segment()], [segment()]) :: {[segment()], [segment()]}
  def partition(segments, walls) do
    segments
    |> Enum.map(fn {axis, position, first, last} ->
      covering =
        for {^axis, ^position, wall_first, wall_last} <- walls,
            wall_first < last and wall_last > first,
            do: {max(first, wall_first), min(last, wall_last)}

      to_segment = fn {part_first, part_last} -> {axis, position, part_first, part_last} end

      {Enum.map(union(covering), to_segment),
       Enum.map(subtract({first, last}, covering), to_segment)}
    end)
    |> Enum.reduce({[], []}, fn {covered, uncovered}, {all_covered, all_uncovered} ->
      {all_covered ++ covered, all_uncovered ++ uncovered}
    end)
  end

  # Edges carry their outward side so that two rectangles' shared edge cancels out.
  defp edges(%{x: x, y: y, width: width, depth: depth}) do
    [
      {:horizontal, y, x, x + width, :north},
      {:horizontal, y + depth, x, x + width, :south},
      {:vertical, x, y, y + depth, :west},
      {:vertical, x + width, y, y + depth, :east}
    ]
  end

  defp opposite?(
         {axis, position, _first, _last, side},
         {axis, position, _other_first, _other_last, other_side}
       ),
       do: opposite_side(side) == other_side

  defp opposite?(_edge, _other), do: false

  defp opposite_side(:north), do: :south
  defp opposite_side(:south), do: :north
  defp opposite_side(:west), do: :east
  defp opposite_side(:east), do: :west

  defp interval({_axis, _position, first, last, _side}), do: {first, last}

  defp with_interval({axis, position, _first, _last, _side}, {first, last}),
    do: {axis, position, first, last}

  defp shared_length(
         {axis, position, first, last, _side},
         {axis, position, other_first, other_last, _other_side}
       ),
       do: max(0, min(last, other_last) - max(first, other_first))

  defp shared_length(_edge, _other), do: 0

  # Removes the intervals from {first, last}; keeps parts of positive length.
  defp subtract(interval, removed) do
    removed
    |> Enum.sort()
    |> Enum.reduce([interval], fn removed_interval, remaining ->
      Enum.flat_map(remaining, &cut(&1, removed_interval))
    end)
  end

  defp cut({first, last}, {removed_first, removed_last}) do
    Enum.filter(
      [{first, min(last, removed_first)}, {max(first, removed_last), last}],
      fn {part_first, part_last} -> part_last > part_first end
    )
  end

  defp union(intervals) do
    intervals
    |> Enum.sort()
    |> Enum.reduce([], fn
      {first, last}, [{previous_first, previous_last} | merged] when first <= previous_last ->
        [{previous_first, max(last, previous_last)} | merged]

      interval, merged ->
        [interval | merged]
    end)
    |> Enum.reverse()
  end

  defp component(rectangles, [], reached), do: Enum.filter(rectangles, &(&1 in reached))

  defp component(rectangles, [current | queue], reached) do
    neighbours = Enum.filter(rectangles, &(&1 not in reached and touch?(current, &1)))
    component(rectangles, queue ++ neighbours, reached ++ neighbours)
  end
end
