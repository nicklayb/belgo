defmodule Belgo.Plans.PlacementForm do
  @moduledoc """
  The fields of a placed device's form (pure), shared by the plan editor and the 3D
  view: its anchor, its height from the floor, its offset in its room and its box.

  The offset is measured from the room's corner (the smallest x and y of its
  rectangles, the top left corner of the 2D drawing), whatever the frame the
  placement is stored in (`Belgo.Plans.Layout`). `attributes/3` turns submitted
  fields back into the attributes of `Belgo.Plans.Editing.update_placement/3`
  (absolute positions): a box is applied once its three dimensions are typed,
  cleared once they are all empty, left unchanged while it is being typed.
  """

  alias Belgo.Plans.Layout
  alias Belgo.Plans.Placement
  alias Belgo.Plans.Plan
  alias Belgo.Plans.Shape
  alias Belgo.Plans.Zone

  @shape_dimensions ~w(width depth height)a

  @type values :: %{String.t() => String.t() | integer() | map() | nil}

  @doc """
  The form values of a placed device (string keys, like submitted params), or `nil`
  when the device is not on the plan.
  """
  @spec values(Plan.t(), String.t()) :: values() | nil
  def values(%Plan{} = plan, device_id) do
    resolved = Layout.resolve(plan)

    with %Placement{} = placement <- find_placement(resolved, device_id),
         %Zone{} = zone <- Enum.find(resolved.zones, &(&1.id == placement.zone_id)) do
      {corner_x, corner_y} = corner(zone)

      %{
        "anchor" => Atom.to_string(placement.anchor),
        "height" => placement.height,
        "offset_x" => placement.x - corner_x,
        "offset_y" => placement.y - corner_y,
        "shape" => shape_values(placement.shape)
      }
    end
  end

  @doc """
  The attributes for `Belgo.Plans.Editing.update_placement/3` from submitted fields;
  blank or invalid fields are left out, offsets become absolute positions.
  """
  @spec attributes(Plan.t(), String.t(), map()) :: map()
  def attributes(%Plan{} = plan, device_id, params) do
    %{}
    |> put_present(:anchor, parse_anchor(params["anchor"]))
    |> put_present(:height, parse_integer(params["height"]))
    |> put_position(plan, device_id, params)
    |> put_shape(params["shape"])
  end

  defp put_position(attributes, plan, device_id, params) do
    offset_x = parse_integer(params["offset_x"])
    offset_y = parse_integer(params["offset_y"])
    resolved = Layout.resolve(plan)

    with %Placement{zone_id: zone_id} <- find_placement(resolved, device_id),
         %Zone{} = zone <- Enum.find(resolved.zones, &(&1.id == zone_id)) do
      {corner_x, corner_y} = corner(zone)

      attributes
      |> put_present(:x, offset_x && corner_x + offset_x)
      |> put_present(:y, offset_y && corner_y + offset_y)
    else
      nil -> attributes
    end
  end

  defp put_shape(attributes, %{} = params) do
    dimensions =
      Map.new(@shape_dimensions, &{&1, parse_positive(params[Atom.to_string(&1)])})

    cond do
      Enum.all?(Map.values(dimensions), &is_nil/1) -> Map.put(attributes, :shape, nil)
      Enum.any?(Map.values(dimensions), &is_nil/1) -> attributes
      true -> Map.put(attributes, :shape, struct(Shape, dimensions))
    end
  end

  defp put_shape(attributes, _params), do: attributes

  defp shape_values(nil), do: Map.new(@shape_dimensions, &{Atom.to_string(&1), nil})

  defp shape_values(%Shape{} = shape),
    do: Map.new(@shape_dimensions, &{Atom.to_string(&1), Map.fetch!(shape, &1)})

  defp find_placement(plan, device_id),
    do: Enum.find(plan.placements, &(&1.device_id == device_id))

  defp corner(%Zone{rectangles: []}), do: {0, 0}

  defp corner(%Zone{rectangles: rectangles}),
    do: {Enum.min_by(rectangles, & &1.x).x, Enum.min_by(rectangles, & &1.y).y}

  defp parse_anchor(value),
    do: Enum.find(Placement.anchors(), &(Atom.to_string(&1) == value))

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) do
    case Integer.parse(value || "") do
      {number, ""} -> number
      _invalid -> nil
    end
  end

  defp parse_positive(value) do
    case parse_integer(value) do
      number when is_integer(number) and number > 0 -> number
      _invalid -> nil
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
