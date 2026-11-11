defmodule Belgo.Plans.PlacementFormTest do
  use ExUnit.Case, async: true

  alias Belgo.Plans.Editing
  alias Belgo.Plans.PlacementForm
  alias Belgo.Plans.Shape

  setup do
    plan = Editing.new_plan("742 Evergreen Terrace")
    {:ok, plan, basement} = Editing.add_level(plan, "Basement", nil, 0, false)

    {:ok, plan, _zone_id} =
      Editing.add_zone(plan, basement, [%{x: 100, y: 50, width: 800, depth: 400}], "Rumpus Room")

    {:ok, plan} = Editing.place_device(plan, "burns-node", basement, 400, 200)
    %{plan: plan, basement: basement}
  end

  test "values measure the offset from the room's corner", %{plan: plan} do
    assert %{
             "anchor" => "floor",
             "height" => 0,
             "offset_x" => 300,
             "offset_y" => 150,
             "shape" => %{"width" => nil, "depth" => nil, "height" => nil}
           } = PlacementForm.values(plan, "burns-node")

    assert nil == PlacementForm.values(plan, "plow-king")
  end

  test "attributes turn offsets back into positions and a full box into a shape", %{plan: plan} do
    params = %{
      "anchor" => "float",
      "height" => "90",
      "offset_x" => "20",
      "offset_y" => "",
      "shape" => %{"width" => "60", "depth" => "40", "height" => "180"}
    }

    assert %{
             anchor: :float,
             height: 90,
             x: 120,
             shape: %Shape{width: 60, depth: 40, height: 180}
           } = attributes = PlacementForm.attributes(plan, "burns-node", params)

    refute Map.has_key?(attributes, :y)

    {:ok, plan} = Editing.update_placement(plan, "burns-node", attributes)
    assert %{"offset_x" => 20, "offset_y" => 150} = PlacementForm.values(plan, "burns-node")
  end

  test "a box being typed is left unchanged, an emptied one is removed", %{plan: plan} do
    partial = %{"shape" => %{"width" => "60", "depth" => "", "height" => ""}}
    refute Map.has_key?(PlacementForm.attributes(plan, "burns-node", partial), :shape)

    emptied = %{"shape" => %{"width" => "", "depth" => "", "height" => ""}}
    assert %{shape: nil} = PlacementForm.attributes(plan, "burns-node", emptied)
  end
end
