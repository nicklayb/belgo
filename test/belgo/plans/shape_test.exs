defmodule Belgo.Plans.ShapeTest do
  use ExUnit.Case, async: true

  alias Belgo.Plans.Placement
  alias Belgo.Plans.Rectangle
  alias Belgo.Plans.Shape
  alias Belgo.Plans.Zone

  @basement %Zone{
    id: "basement",
    name: "Basement",
    level_id: "basement",
    rectangles: [%Rectangle{x: 100, y: 100, width: 400, depth: 300}]
  }
  @shape %Shape{width: 60, depth: 100, height: 200}

  test "a point has no footprint, a floor box is centred on it" do
    placement = %Placement{device_id: "reactor", zone_id: "basement", x: 300, y: 250}

    assert nil == Shape.footprint(placement, @basement)

    assert %{x: 270, y: 200, width: 60, depth: 100} =
             Shape.footprint(%{placement | shape: @shape}, @basement)
  end

  test "a wall box lies along its wall and stands into the room" do
    on_west_wall = %Placement{
      device_id: "rack",
      zone_id: "basement",
      anchor: :wall,
      x: 100,
      y: 250,
      height: 0,
      shape: @shape
    }

    assert %{x: 100, y: 220, width: 100, depth: 60} = Shape.footprint(on_west_wall, @basement)

    on_east_wall = %{on_west_wall | x: 500}
    assert %{x: 400, y: 220, width: 100, depth: 60} = Shape.footprint(on_east_wall, @basement)

    on_north_wall = %{on_west_wall | x: 300, y: 100}
    assert %{x: 270, y: 100, width: 60, depth: 100} = Shape.footprint(on_north_wall, @basement)

    # A floor device against a wall (a rack) also has its back on the wall.
    assert %{x: 100, y: 220, width: 100, depth: 60} =
             Shape.footprint(%{on_west_wall | anchor: :floor}, @basement)

    # With a gap, the back touches the inner face of the wall.
    assert %{x: 105} = Shape.footprint(on_west_wall, @basement, 5)
    assert %{x: 395} = Shape.footprint(on_east_wall, @basement, 5)
  end

  test "every dimension is required and positive" do
    assert %{valid?: true} = Shape.changeset(%Shape{}, %{width: 60, depth: 40, height: 180})
    assert %{valid?: false} = Shape.changeset(%Shape{}, %{width: 60, depth: 0})
  end
end
