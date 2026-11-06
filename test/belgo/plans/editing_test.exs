defmodule Belgo.Plans.EditingTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Codec
  alias Belgo.Plans.Analysis
  alias Belgo.Plans.Editing
  alias Belgo.Plans.Geometry

  @snapshot %Belgo.Inventory.Snapshot{}

  setup do
    plan = Editing.new_plan("742 Evergreen Terrace")
    {:ok, plan, basement} = Editing.add_level(plan, "Basement", nil, 0, false)

    {:ok, plan, _zone_id} =
      Editing.add_zone(plan, basement, [%{x: 0, y: 0, width: 800, depth: 400}], "Rumpus Room")

    %{plan: plan, basement: basement}
  end

  test "a new home is valid once saved", %{plan: plan} do
    assert %{id: "742-evergreen-terrace"} = plan
    assert {:ok, _decoded} = Codec.decode(:plans, Codec.encode(plan))
  end

  test "a level stacked on another starts with its footprint", %{plan: plan, basement: basement} do
    {:ok, plan, ground_floor} = Editing.add_level(plan, "Ground floor", basement, 1, true)

    assert %{level_id: ^ground_floor, rectangles: [%{x: 0, y: 0, width: 800, depth: 400}]} =
             Enum.find(plan.zones, &(&1.level_id == ground_floor))

    # A garage half a level up, next to it, starts empty.
    {:ok, plan, garage} = Editing.add_level(plan, "Garage", basement, 0.5, false)
    refute Enum.any?(plan.zones, &(&1.level_id == garage))
  end

  test "splitting a room makes two touching rooms", %{plan: plan} do
    {:ok, plan, kitchen} = Editing.split_zone(plan, "rumpus-room", :vertical, 500, "Kitchen")

    rumpus = Enum.find(plan.zones, &(&1.id == "rumpus-room"))
    kitchen = Enum.find(plan.zones, &(&1.id == kitchen))
    assert [%{width: 500}] = rumpus.rectangles
    assert [%{x: 500, width: 300}] = kitchen.rectangles
    assert Geometry.touch?(hd(rumpus.rectangles), hd(kitchen.rectangles))

    assert {:error, "the line does not cross the room"} =
             Editing.split_zone(plan, "kitchen", :vertical, 2000, "Nowhere")
  end

  test "a door snaps to the nearest wall and stays on it", %{plan: plan, basement: basement} do
    {:ok, plan, _kitchen} = Editing.split_zone(plan, "rumpus-room", :vertical, 500, "Kitchen")
    analysis = Analysis.build(plan, @snapshot)

    {:ok, plan} = Editing.add_opening(plan, analysis, basement, 510, 30, :door)
    assert [%{axis: :vertical, x: 500, y: 0, width: 90}] = plan.openings
    assert [] == Analysis.build(plan, @snapshot).warnings

    assert {:error, _message} = Editing.add_opening(plan, analysis, basement, 250, 200, :door)
  end

  test "an orphan room is anchored against its neighbour", %{plan: plan, basement: basement} do
    {:ok, plan, shed} =
      Editing.add_zone(plan, basement, [%{x: 2000, y: 1000, width: 200, depth: 200}], "Shed")

    assert [^shed] = Analysis.build(plan, @snapshot).orphan_zone_ids

    {:ok, plan} = Editing.anchor_zone(plan, shed)
    assert [] == Analysis.build(plan, @snapshot).orphan_zone_ids
  end

  test "moving a room moves its devices", %{plan: plan} do
    plan = %{
      plan
      | placements: [
          %Belgo.Plans.Placement{device_id: "burns-node", zone_id: "rumpus-room", x: 100, y: 100}
        ]
    }

    {:ok, plan} = Editing.move_zone(plan, "rumpus-room", 50, -20)

    assert [%{x: 50, y: -20}] = Enum.map(hd(plan.zones).rectangles, &Map.take(&1, [:x, :y]))
    assert [%{x: 150, y: 80}] = plan.placements
  end

  test "unique identifiers and a room keeps a rectangle", %{plan: plan, basement: basement} do
    {:ok, plan, second} =
      Editing.add_zone(plan, basement, [%{x: 800, y: 0, width: 100, depth: 100}], "Rumpus Room")

    assert "rumpus-room-2" == second
    assert {:error, _message} = Editing.delete_rectangle(plan, "rumpus-room", 0)
    assert 120 == Editing.snap(123, 10)
  end

  describe "placing devices" do
    test "on the floor inside a room, on a wall near one", %{plan: plan, basement: basement} do
      {:ok, plan} = Editing.place_device(plan, "burns-node", basement, 300, 200)

      assert [
               %{
                 device_id: "burns-node",
                 zone_id: "rumpus-room",
                 anchor: :floor,
                 x: 300,
                 y: 200,
                 height: 0
               }
             ] = plan.placements

      # 20 cm from the north wall: hung on it, at the default height.
      {:ok, plan} = Editing.place_device(plan, "tv-living-room", basement, 410, 20)

      assert %{anchor: :wall, x: 410, y: 0, height: 150} =
               Enum.find(plan.placements, &(&1.device_id == "tv-living-room"))

      assert {:error, _message} = Editing.place_device(plan, "smithers", basement, 3000, 3000)
    end

    test "placing again moves the device, keeping one placement", %{
      plan: plan,
      basement: basement
    } do
      {:ok, plan} = Editing.place_device(plan, "burns-node", basement, 300, 200)
      {:ok, plan} = Editing.place_device(plan, "burns-node", basement, 100, 100)
      assert [%{x: 100, y: 100}] = plan.placements
    end

    test "anchoring to a wall snaps to the nearest wall", %{plan: plan, basement: basement} do
      {:ok, plan} = Editing.place_device(plan, "burns-node", basement, 700, 200)
      {:ok, plan} = Editing.update_placement(plan, "burns-node", %{anchor: :wall})
      assert [%{anchor: :wall, x: 800, y: 200, height: 150}] = plan.placements

      {:ok, plan} = Editing.update_placement(plan, "burns-node", %{anchor: :floor})
      assert [%{anchor: :floor, height: 0}] = plan.placements

      {:ok, plan} = Editing.remove_placement(plan, "burns-node")
      assert [] == plan.placements
    end
  end

  describe "adding a room next to another" do
    test "offers the free sides only", %{plan: plan, basement: basement} do
      {:ok, plan, _kitchen} =
        Editing.add_zone(plan, basement, [%{x: 800, y: 0, width: 300, depth: 400}], "Kitchen")

      sides = Editing.free_sides(plan, "rumpus-room")
      # The east side touches the kitchen.
      assert [:north, :south, :west] == Enum.map(sides, & &1.side)

      assert %{rectangle: %{x: 0, y: -300, width: 800, depth: 300}} =
               Enum.find(sides, &(&1.side == :north))
    end

    test "creates the room along the whole side", %{plan: plan} do
      index = Enum.find_index(Editing.free_sides(plan, "rumpus-room"), &(&1.side == :south))
      {:ok, plan, porch} = Editing.add_adjacent_zone(plan, "rumpus-room", index, "Porch")

      assert %{rectangles: [%{x: 0, y: 400, width: 800, depth: 300}]} =
               Enum.find(plan.zones, &(&1.id == porch))

      refute Enum.any?(Editing.free_sides(plan, "rumpus-room"), &(&1.side == :south))
    end

    test "an L-shaped room has one free side per outer segment", %{plan: plan} do
      {:ok, plan} =
        Editing.add_rectangle(plan, "rumpus-room", %{x: 0, y: 400, width: 300, depth: 300})

      south_sides =
        for %{side: :south} = side <- Editing.free_sides(plan, "rumpus-room"), do: side.rectangle

      assert [%{x: 0, y: 700, width: 300}, %{x: 300, y: 400, width: 500}] =
               Enum.sort_by(south_sides, & &1.x)
    end
  end
end
