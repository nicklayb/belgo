defmodule Belgo.Plans.SceneTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Storage.YamlDirectory
  alias Belgo.Inventory.Snapshot
  alias Belgo.Plans.Analysis
  alias Belgo.Plans.Level
  alias Belgo.Plans.Opening
  alias Belgo.Plans.Placement
  alias Belgo.Plans.Plan
  alias Belgo.Plans.Rectangle
  alias Belgo.Plans.Scene
  alias Belgo.Plans.Shape
  alias Belgo.Plans.Zone

  @examples Path.expand("../../../examples/inventory", __DIR__)

  test "a wall is split around a door, with a lintel above it" do
    door = %Opening{level_id: "basement", x: 100, y: 0, axis: :horizontal, width: 90, kind: :door}

    assert [
             %{kind: :wall, x1: 0, x2: 100, bottom: 0, top: 250},
             %{kind: :lintel, x1: 100, x2: 190, bottom: 210, top: 250},
             %{kind: :door, x1: 100, x2: 190, bottom: 0, top: 210},
             %{kind: :wall, x1: 190, x2: 500, bottom: 0, top: 250}
           ] = Scene.split_wall({:horizontal, 0, 0, 500}, [door], 0, 250)
  end

  test "an opening keeps a lintel but no door, and low walls keep a lintel too" do
    opening = %Opening{
      level_id: "attic",
      x: 0,
      y: 100,
      axis: :vertical,
      width: 120,
      kind: :opening
    }

    assert [%{kind: :lintel, bottom: 180, top: 200}, %{kind: :wall, y1: 220, y2: 300}] =
             Scene.split_wall({:vertical, 0, 100, 300}, [opening], 0, 200)
  end

  test "the example home: levels at their height, exterior at the ground, devices placed" do
    {:ok, snapshot} = YamlDirectory.load(path: @examples)
    plan = hd(snapshot.plans)
    scene = Scene.build(plan, Analysis.build(plan, snapshot), snapshot)

    assert ["sous-sol", "garage", "rez-de-chaussee", "etage"] == Enum.map(scene.levels, & &1.id)

    assert %{elevation: 216.0, exterior: true} =
             Enum.find(scene.floors, &(&1.zone_id == "terrain"))

    assert %{elevation: 405.0} = Enum.find(scene.floors, &(&1.zone_id == "chambre"))
    # The Apple TV hangs on the living room wall, 1.20 m above the ground floor.
    assert %{elevation: 390.0, anchor: :wall} =
             Enum.find(scene.devices, &(&1.device_id == "apple-tv-salon"))
  end

  test "walls take their level's height and mark the facade; boxed devices get a box" do
    plan = %Plan{
      id: "evergreen-terrace",
      name: "742 Evergreen Terrace",
      levels: [%Level{id: "ground-floor", name: "Ground floor", wall_height: 300}],
      zones: [
        %Zone{
          id: "living-room",
          name: "Living room",
          level_id: "ground-floor",
          rectangles: [%Rectangle{x: 0, y: 0, width: 400, depth: 300}]
        },
        %Zone{
          id: "kitchen",
          name: "Kitchen",
          level_id: "ground-floor",
          rectangles: [%Rectangle{x: 400, y: 0, width: 300, depth: 300}]
        }
      ],
      placements: [
        %Placement{
          device_id: "television",
          zone_id: "living-room",
          anchor: :wall,
          x: 200,
          y: 300,
          height: 80,
          shape: %Shape{width: 120, depth: 10, height: 70}
        }
      ]
    }

    snapshot = %Snapshot{}
    scene = Scene.build(plan, Analysis.build(plan, snapshot), snapshot)

    assert Enum.all?(scene.walls, &(&1.top == 300))

    assert [
             %{name: "Living room", x: 0, width: 400, elevation: 0.0},
             %{name: "Kitchen", x: 400, width: 300}
           ] = scene.room_labels

    assert [%{x1: 400, x2: 400, y1: 0, y2: 300}] = Enum.reject(scene.walls, & &1.exterior)
    assert %{floors: [%{top: 300.0} | _]} = scene

    # On the south wall, its back against the wall's inner face (half of 10 cm).
    assert [%{elevation: 80.0, box: %{x: 140, y: 285, width: 120, depth: 10, height: 70}}] =
             scene.devices
  end
end
