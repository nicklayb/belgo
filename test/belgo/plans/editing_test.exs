defmodule Belgo.Plans.EditingTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Codec
  alias Belgo.Plans.Analysis
  alias Belgo.Plans.Editing
  alias Belgo.Plans.Geometry
  alias Belgo.Plans.Layout
  alias Belgo.Plans.Opening
  alias Belgo.Plans.Placement

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

  test "splitting a room makes two touching rooms, the new one anchored", %{plan: plan} do
    {:ok, plan, kitchen} = Editing.split_zone(plan, "rumpus-room", :vertical, 500, "Kitchen")

    assert [%{width: 500} = rumpus_rectangle] = placed(plan, "rumpus-room")
    assert [%{x: 500, y: 0, width: 300} = kitchen_rectangle] = placed(plan, kitchen)
    assert Geometry.touch?(rumpus_rectangle, kitchen_rectangle)

    assert %{anchor: %{zone_id: "rumpus-room", side: :east, offset: 0}} =
             Enum.find(plan.zones, &(&1.id == kitchen))

    assert {:error, "the line does not cross the room"} =
             Editing.split_zone(plan, "kitchen", :vertical, 2000, "Nowhere")
  end

  test "a door snaps to the nearest wall and stays on it", %{plan: plan, basement: basement} do
    {:ok, plan, _kitchen} = Editing.split_zone(plan, "rumpus-room", :vertical, 500, "Kitchen")
    analysis = Analysis.build(plan, @snapshot)

    {:ok, plan} = Editing.add_opening(plan, analysis, basement, 510, 30, :door)
    assert [%Opening{zone_id: _room, align: :start, offset: 0, width: 90, x: nil}] = plan.openings
    assert [%{axis: :vertical, x: 500, y: 0}] = Layout.resolve(plan).openings
    assert [] == Analysis.build(plan, @snapshot).warnings

    assert {:error, _message} = Editing.add_opening(plan, analysis, basement, 250, 200, :door)
  end

  test "an orphan room is anchored against its neighbour", %{plan: plan, basement: basement} do
    {:ok, plan, shed} =
      Editing.add_zone(plan, basement, [%{x: 2000, y: 1000, width: 200, depth: 200}], "Shed")

    assert [^shed] = Analysis.build(plan, @snapshot).orphan_zone_ids

    {:ok, plan} = Editing.anchor_zone(plan, shed)
    assert [] == Analysis.build(plan, @snapshot).orphan_zone_ids
    assert %{anchor: %{zone_id: "rumpus-room"}} = Enum.find(plan.zones, &(&1.id == shed))
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

  defp placed(plan, zone_id) do
    plan
    |> Layout.resolve()
    |> Map.fetch!(:zones)
    |> Enum.find(&(&1.id == zone_id))
    |> Map.fetch!(:rectangles)
  end

  defp analysis(plan), do: Analysis.build(plan, @snapshot)

  defp warning_kinds(plan), do: Enum.map(analysis(plan).warnings, & &1.kind)

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

    test "placing again moves the device with its box, keeping one placement", %{
      plan: plan,
      basement: basement
    } do
      {:ok, plan} = Editing.place_device(plan, "burns-node", basement, 300, 200)
      shape = %Belgo.Plans.Shape{width: 60, depth: 40, height: 180}
      {:ok, plan} = Editing.update_placement(plan, "burns-node", %{shape: shape})
      {:ok, plan} = Editing.place_device(plan, "burns-node", basement, 100, 100)
      assert [%{x: 100, y: 100, shape: ^shape}] = plan.placements
    end

    test "a floor device moved near a wall stays on the floor, against it", %{
      plan: plan,
      basement: basement
    } do
      {:ok, plan} = Editing.place_device(plan, "burns-node", basement, 400, 200)
      assert [%{anchor: :floor}] = plan.placements
      {:ok, plan} = Editing.place_device(plan, "burns-node", basement, 790, 200)
      assert [%{anchor: :floor, x: 800, y: 200, height: 0}] = plan.placements
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

  describe "anchored rooms" do
    setup %{plan: plan} do
      index = Enum.find_index(Editing.free_sides(plan, "rumpus-room"), &(&1.side == :east))
      {:ok, plan, kitchen} = Editing.add_adjacent_zone(plan, "rumpus-room", index, "Kitchen")
      %{plan: plan, kitchen: kitchen}
    end

    test "follow their parent when it is resized or moved", %{plan: plan, kitchen: kitchen} do
      assert [%{x: 800, y: 0, width: 300, depth: 400}] = placed(plan, kitchen)

      {:ok, plan} =
        Editing.set_rectangle(plan, "rumpus-room", 0, %{x: 0, y: 0, width: 650, depth: 400})

      assert [%{x: 650, y: 0}] = placed(plan, kitchen)

      {:ok, plan} = Editing.move_zone(plan, "rumpus-room", 100, 50)
      assert [%{x: 750, y: 50}] = placed(plan, kitchen)
    end

    test "cannot be moved; resized, they keep their anchored wall", %{
      plan: plan,
      kitchen: kitchen
    } do
      assert {:error, _message} = Editing.move_zone(plan, kitchen, 100, 0)

      # Dragging its west edge into the rumpus room: it grows east instead.
      {:ok, plan} =
        Editing.set_rectangle(plan, kitchen, 0, %{x: 700, y: 0, width: 400, depth: 400})

      assert [%{x: 800, y: 0, width: 400}] = placed(plan, kitchen)

      # Along the wall, the offset follows the edit.
      {:ok, plan} =
        Editing.set_rectangle(plan, kitchen, 0, %{x: 800, y: 100, width: 400, depth: 200})

      assert %{anchor: %{offset: 100}} = Enum.find(plan.zones, &(&1.id == kitchen))
      assert [%{x: 800, y: 100, depth: 200}] = placed(plan, kitchen)
    end

    test "their devices and openings follow them", %{plan: plan, kitchen: kitchen} do
      {:ok, plan} = Editing.place_device(plan, "burns-node", "basement", 900, 200)
      assert [%Placement{zone_id: ^kitchen, x: 100, y: 200}] = plan.placements

      {:ok, plan} = Editing.add_opening(plan, analysis(plan), "basement", 1100, 205, :door)

      {:ok, plan} =
        Editing.set_rectangle(plan, "rumpus-room", 0, %{x: 0, y: 0, width: 500, depth: 400})

      resolved = Layout.resolve(plan)
      assert [%{x: 600, y: 200}] = resolved.placements
      assert [%{axis: :vertical, x: 800}] = resolved.openings
      # Burns Node is not in the (empty) inventory: nothing else to report.
      assert [:unknown_device] == warning_kinds(plan)
    end

    test "deleting a parent leaves its children where they were, as roots", %{
      plan: plan,
      kitchen: kitchen
    } do
      {:ok, plan} = Editing.place_device(plan, "burns-node", "basement", 900, 200)
      {:ok, plan} = Editing.delete_zone(plan, "rumpus-room")

      assert %{anchor: nil, rectangles: [%{x: 800, y: 0, width: 300}]} =
               Enum.find(plan.zones, &(&1.id == kitchen))

      assert [%{x: 900, y: 200}] = plan.placements

      # The kitchen is the main room of the level now: re-add a room and anchor it.
      {:ok, plan, shed} =
        Editing.add_zone(plan, "basement", [%{x: 0, y: 30, width: 200, depth: 200}], "Shed")

      # Anchoring is optional: a root room is not a problem.
      refute :unanchored_zone in warning_kinds(plan)
      assert shed in Analysis.unanchored_zone_ids(plan)

      # Its north wall cannot face the kitchen's west wall…
      assert {:error, _message} = Editing.anchor_to(plan, shed, {0, :north}, kitchen, {0, :west})

      # …its east wall can: it moves across to touch, keeping its height along the wall.
      {:ok, plan} = Editing.anchor_to(plan, shed, {0, :east}, kitchen, {0, :west})
      assert [%{x: 600, y: 30}] = placed(plan, shed)
      assert [:unknown_device] == warning_kinds(plan)

      # A parent cannot be anchored to its child.
      assert {:error, _message} = Editing.anchor_to(plan, kitchen, {0, :west}, shed, {0, :east})
    end

    test "detach, align and offset", %{plan: plan, kitchen: kitchen} do
      {:ok, plan} = Editing.update_anchor(plan, kitchen, %{offset: 50})
      assert [%{y: 50}] = placed(plan, kitchen)

      # A new alignment alone keeps the room where it is.
      {:ok, plan} = Editing.update_anchor(plan, kitchen, %{align: :end})
      assert %{anchor: %{align: :end, offset: -50}} = Enum.find(plan.zones, &(&1.id == kitchen))
      assert [%{y: 50}] = placed(plan, kitchen)

      {:ok, plan} = Editing.update_anchor(plan, kitchen, %{align: :center})

      assert %{anchor: %{align: :center, offset: nil}} =
               Enum.find(plan.zones, &(&1.id == kitchen))

      assert [%{y: 0}] = placed(plan, kitchen)

      {:ok, plan} = Editing.detach_zone(plan, kitchen)

      assert %{anchor: nil, rectangles: [%{x: 800, y: 0}]} =
               Enum.find(plan.zones, &(&1.id == kitchen))
    end
  end

  test "an opening is aligned on its wall by its start, its end or its centre", %{
    plan: plan,
    basement: basement
  } do
    {:ok, plan} = Editing.add_opening(plan, analysis(plan), basement, 300, 395, :opening)
    # South wall: its start is the east end (x = 800).
    assert [%{side: :south, align: :start, offset: 440, width: 120}] = plan.openings

    {:ok, plan} = Editing.update_opening(plan, 0, %{offset: 50, width: 150})
    assert [%{x: 600, width: 150}] = Layout.resolve(plan).openings

    {:ok, plan} = Editing.update_opening(plan, 0, %{align: :end})
    assert [%{align: :end, offset: 600}] = plan.openings

    {:ok, plan} = Editing.update_opening(plan, 0, %{align: :center})
    assert [%{offset: nil}] = plan.openings
    assert [%{x: 325}] = Layout.resolve(plan).openings
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

      assert %{
               anchor: %{zone_id: "rumpus-room", side: :south, align: :start, offset: 0},
               rectangles: [%{x: nil, y: nil, width: 800, depth: 300}]
             } = Enum.find(plan.zones, &(&1.id == porch))

      assert [%{x: 0, y: 400, width: 800, depth: 300}] = placed(plan, porch)
      assert {:ok, _decoded} = Codec.decode(:plans, Codec.encode(plan))

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
