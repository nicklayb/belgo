defmodule Belgo.Plans.SceneTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Storage.YamlDirectory
  alias Belgo.Plans.Analysis
  alias Belgo.Plans.Opening
  alias Belgo.Plans.Scene

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
end
