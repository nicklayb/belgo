defmodule Belgo.Plans.GeometryTest do
  use ExUnit.Case, async: true

  alias Belgo.Plans.Geometry

  @kwik_e_mart %{x: 0, y: 0, width: 500, depth: 400}
  @storage_room %{x: 500, y: 0, width: 300, depth: 400}
  @back_room %{x: 0, y: 400, width: 800, depth: 200}

  test "overlap needs a shared surface, touching needs a shared edge" do
    assert Geometry.touch?(@kwik_e_mart, @storage_room)
    refute Geometry.overlap?(@kwik_e_mart, @storage_room)
    assert Geometry.overlap?(@kwik_e_mart, %{@storage_room | x: 450})
    # Corners only: not touching.
    refute Geometry.touch?(@kwik_e_mart, %{x: 500, y: 400, width: 100, depth: 100})
  end

  test "an L-shaped zone has walls on its outline only" do
    outline = Geometry.outline([@storage_room, @back_room])

    assert {:horizontal, 400, 0, 500} in outline
    # The edge shared by both rectangles is not a wall.
    refute Enum.any?(outline, &match?({:horizontal, 400, 500, 800}, &1))
    assert Geometry.connected?([@storage_room, @back_room])
    refute Geometry.connected?([@kwik_e_mart, %{@back_room | y: 700}])
  end

  test "a wall between two rooms exists once and openings must lie on walls" do
    walls =
      Geometry.merge(Geometry.outline([@kwik_e_mart]) ++ Geometry.outline([@storage_room]))

    assert [{:vertical, 500, 0, 400}] ==
             Enum.filter(walls, &match?({:vertical, 500, _first, _last}, &1))

    assert Geometry.on_walls?(walls, {:vertical, 500, 100, 190})
    refute Geometry.on_walls?(walls, {:vertical, 250, 100, 190})
    assert Geometry.point_on_walls?(walls, 500, 250)
  end

  test "measures: surface, bounds, points inside" do
    assert 500 * 400 + 800 * 200 == Geometry.area([@kwik_e_mart, @back_room])
    assert %{x: 0, y: 0, width: 800, depth: 600} == Geometry.bounds([@kwik_e_mart, @back_room])
    assert Geometry.contains_point?([@kwik_e_mart], 500, 400)
    refute Geometry.contains_point?([@kwik_e_mart], 501, 10)
  end

  test "subtracting rectangles leaves the uncovered parts" do
    yard = %{x: 0, y: 0, width: 1000, depth: 600}
    house = %{x: 200, y: 200, width: 400, depth: 200}
    parts = Geometry.subtract_rectangles(yard, [house])

    assert Geometry.area(parts) == 1000 * 600 - 400 * 200
    refute Enum.any?(parts, &Geometry.overlap?(&1, house))
    assert [yard] == Geometry.subtract_rectangles(yard, [%{x: 2000, y: 0, width: 10, depth: 10}])
  end
end
