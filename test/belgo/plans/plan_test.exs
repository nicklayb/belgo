defmodule Belgo.Plans.PlanTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Codec
  alias Belgo.Inventory.Storage.YamlDirectory
  alias Belgo.Plans.Analysis
  alias Belgo.Plans.Levels
  alias Belgo.Plans.Plan

  @examples Path.expand("../../../examples/inventory", __DIR__)

  setup do
    {:ok, snapshot} = YamlDirectory.load(path: @examples)
    %{snapshot: snapshot, plan: hd(snapshot.plans)}
  end

  test "the example home loads, levels relative to each other", %{plan: plan} do
    assert %Plan{id: "maison", name: "Maison", level_height: 270} = plan

    assert {:ok,
            %{"sous-sol" => 0.0, "garage" => 135.0, "rez-de-chaussee" => 270.0, "etage" => 405.0}} =
             Levels.elevations(plan.levels, plan.level_height)
  end

  test "is stored as drawn, nothing computed", %{plan: plan} do
    encoded = Codec.encode(plan)
    refute Map.has_key?(encoded, "elevations")
    assert {:ok, ^plan} = Codec.decode(:plans, Map.put(encoded, "id", plan.id))
  end

  test "analysis: heights, ground, walls and measures stay in memory", %{
    plan: plan,
    snapshot: snapshot
  } do
    analysis = Analysis.build(plan, snapshot)

    # 80 % of the basement height.
    assert 216.0 == analysis.ground_elevation
    assert {:vertical, 500, 0, 400} in analysis.walls_by_level["sous-sol"]
    assert 600 * 800 == analysis.measures["garage"].area
    assert [] == analysis.orphan_zone_ids
    assert [] == analysis.warnings
  end

  describe "changeset" do
    test "zones of a level must not overlap, references must exist", %{plan: plan} do
      params =
        plan
        |> Codec.encode()
        |> Map.put("id", plan.id)
        |> update_in(["zones"], fn zones ->
          zones ++
            [
              %{
                "id" => "moes",
                "name" => "Moe's",
                "level_id" => "sous-sol",
                "rectangles" => [%{"x" => 100, "y" => 100, "width" => 100, "depth" => 100}]
              },
              %{
                "id" => "lisa",
                "name" => "Lisa",
                "level_id" => "grenier",
                "rectangles" => [%{"x" => 3000, "y" => 0, "width" => 100, "depth" => 100}]
              }
            ]
        end)

      assert {:error, changeset} = Codec.decode(:plans, params)
      messages = Enum.map(Keyword.get_values(changeset.errors, :zones), &elem(&1, 0))
      assert "Bureau Nicolas and Moe's overlap" in messages
      assert "Lisa: unknown level grenier" in messages
    end

    test "anchors must resolve", %{plan: plan} do
      params =
        plan
        |> Codec.encode()
        |> Map.put("id", plan.id)
        |> update_in(["zones"], fn zones ->
          Enum.map(zones, fn
            %{"id" => "studio"} = studio -> put_in(studio, ["anchor", "zone_id"], "kwik-e-mart")
            zone -> zone
          end)
        end)

      assert {:error, changeset} = Codec.decode(:plans, params)

      assert "Studio: anchored to unknown room kwik-e-mart" in Enum.map(
               Keyword.get_values(changeset.errors, :zones),
               &elem(&1, 0)
             )
    end

    test "levels must not form a cycle" do
      assert {:error, changeset} =
               Codec.decode(:plans, %{
                 "id" => "springfield",
                 "name" => "Springfield",
                 "levels" => [
                   %{"id" => "itchy", "name" => "Itchy", "base_id" => "scratchy", "offset" => 1},
                   %{
                     "id" => "scratchy",
                     "name" => "Scratchy",
                     "base_id" => "itchy",
                     "offset" => 1
                   }
                 ]
               })

      assert [{"unknown or cyclic base for itchy, scratchy", _}] =
               Keyword.get_values(changeset.errors, :levels)
    end
  end

  describe "warnings" do
    test "resizing a room leaves a device outside, warned", %{plan: plan, snapshot: snapshot} do
      plan =
        update_zone(
          plan,
          "bureau-nicolas",
          &%{&1 | rectangles: [%{hd(&1.rectangles) | width: 50}]}
        )

      warnings = Analysis.build(plan, snapshot).warnings
      assert [%{kind: :outside_zone, device_id: "hades"}] = warnings

      # The studio is anchored to the office's east wall: it follows, with the door
      # on that wall. A door pushed past the end of its wall is reported.
      assert [] == Enum.filter(warnings, &(&1.kind == :opening_off_wall))
      plan = %{plan | openings: Enum.map(plan.openings, &%{&1 | offset: 1000})}
      assert Enum.any?(Analysis.build(plan, snapshot).warnings, &(&1.kind == :opening_off_wall))
    end

    test "deleted devices and locations stay as broken links", %{plan: plan, snapshot: snapshot} do
      snapshot = %{
        snapshot
        | devices: Enum.reject(snapshot.devices, &(&1.id == "hades")),
          locations: []
      }

      warnings = Analysis.build(plan, snapshot).warnings

      assert Enum.any?(warnings, &(&1.kind == :unknown_device and &1.device_id == "hades"))
      assert Enum.any?(warnings, &(&1.kind == :unknown_location and &1.zone_id == "salon"))
    end

    test "a device drawn in another room than its location", %{plan: plan, snapshot: snapshot} do
      plan = %{
        plan
        | placements:
            Enum.map(plan.placements, &%{&1 | zone_id: "salon", anchor: :floor, x: 100, y: 100})
      }

      warnings = Analysis.build(plan, snapshot).warnings

      assert Enum.any?(warnings, &(&1.kind == :location_mismatch and &1.device_id == "hades"))
    end

    test "a room touching nothing is an orphan", %{plan: plan, snapshot: snapshot} do
      plan =
        update_zone(
          plan,
          "chambre-bebe",
          &%{&1 | anchor: nil, rectangles: [%{hd(&1.rectangles) | x: 5000, y: 0}]}
        )

      analysis = Analysis.build(plan, snapshot)

      assert ["chambre-bebe"] == analysis.orphan_zone_ids
      assert Enum.any?(analysis.warnings, &(&1.kind == :orphan_zone))
      # Being a root (not anchored) is fine: only the orphan is reported.
      assert [:orphan_zone] == Enum.map(analysis.warnings, & &1.kind)
    end
  end

  defp update_zone(plan, zone_id, function) do
    %{plan | zones: Enum.map(plan.zones, &if(&1.id == zone_id, do: function.(&1), else: &1))}
  end
end
