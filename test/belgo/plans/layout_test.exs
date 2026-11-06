defmodule Belgo.Plans.LayoutTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Codec
  alias Belgo.Inventory.Storage.YamlDirectory
  alias Belgo.Plans.Anchor
  alias Belgo.Plans.Layout
  alias Belgo.Plans.Opening
  alias Belgo.Plans.Placement
  alias Belgo.Plans.Plan
  alias Belgo.Plans.Rectangle
  alias Belgo.Plans.WallPosition
  alias Belgo.Plans.Zone

  @examples Path.expand("../../../examples/inventory", __DIR__)

  # Moe's Tavern: 400 × 300 at (100, 100); its walls go from 100 to 500 (x) and from
  # 100 to 400 (y).
  @tavern %Zone{
    id: "moes-tavern",
    name: "Moe's Tavern",
    level_id: "springfield",
    rectangles: [%Rectangle{x: 100, y: 100, width: 400, depth: 300}]
  }

  defp plan(zones, extra \\ []),
    do: struct(%Plan{id: "springfield", name: "Springfield"}, [zones: zones] ++ extra)

  defp back_room(side, align, offset, width \\ 100, depth \\ 50) do
    %Zone{
      id: "back-room",
      name: "Back room",
      level_id: "springfield",
      anchor: %Anchor{zone_id: "moes-tavern", side: side, align: align, offset: offset},
      rectangles: [%Rectangle{width: width, depth: depth}]
    }
  end

  defp placed(zones, zone_id) do
    resolved = Layout.resolve(plan(zones))
    Enum.find(resolved.zones, &(&1.id == zone_id))
  end

  describe "anchored rooms" do
    test "lie outside the parent's wall, start and end seen from inside the parent" do
      # North wall: start is its west end, end its east end.
      assert %{rectangles: [%{x: 120, y: 50}]} =
               placed([@tavern, back_room(:north, :start, 20)], "back-room")

      assert %{rectangles: [%{x: 380, y: 50}]} =
               placed([@tavern, back_room(:north, :end, 20)], "back-room")

      # South wall: start is its east end.
      assert %{rectangles: [%{x: 380, y: 400}]} =
               placed([@tavern, back_room(:south, :start, 20)], "back-room")

      # East wall: start is its north end; the room is 100 wide, 50 deep.
      assert %{rectangles: [%{x: 500, y: 120}]} =
               placed([@tavern, back_room(:east, :start, 20)], "back-room")

      assert %{rectangles: [%{x: 500, y: 300}]} =
               placed([@tavern, back_room(:east, :end, 50)], "back-room")
    end

    test "on the west wall, start offset 0: east wall on it, flush with its left (south) end" do
      assert %{rectangles: [%{x: 0, y: 350, width: 100, depth: 50}]} =
               placed([@tavern, back_room(:west, :start, 0)], "back-room")
    end

    test "centred, the offset is not used" do
      assert %{rectangles: [%{x: 250, y: 400}]} =
               placed([@tavern, back_room(:south, :center, nil)], "back-room")
    end

    test "chain: a room anchored to an anchored room follows both" do
      kitchen = %Zone{
        id: "kitchen",
        name: "Kitchen",
        level_id: "springfield",
        anchor: %Anchor{zone_id: "back-room", side: :east, align: :start, offset: 0},
        rectangles: [%Rectangle{width: 80, depth: 50}]
      }

      zones = [@tavern, back_room(:north, :start, 0), kitchen]
      assert %{rectangles: [%{x: 200, y: 50}]} = placed(zones, "kitchen")

      wider = %{@tavern | rectangles: [%Rectangle{x: 0, y: 100, width: 500, depth: 300}]}
      assert %{rectangles: [%{x: 100, y: 50}]} = placed([wider | tl(zones)], "kitchen")
    end

    test "other rectangles and devices are relative to the first rectangle's corner" do
      l_shaped = %{
        back_room(:north, :start, 0)
        | rectangles: [
            %Rectangle{width: 100, depth: 50},
            %Rectangle{x: 100, y: 0, width: 50, depth: 100}
          ]
      }

      plan =
        plan([@tavern, l_shaped],
          placements: [%Placement{device_id: "duff-tap", zone_id: "back-room", x: 10, y: 20}]
        )

      resolved = Layout.resolve(plan)
      room = Enum.find(resolved.zones, &(&1.id == "back-room"))
      assert [%{x: 100, y: 50}, %{x: 200, y: 50}] = room.rectangles
      assert [%{x: 110, y: 70}] = resolved.placements
      assert resolved == Layout.resolve(resolved)
    end
  end

  test "openings sit on their wall by alignment" do
    entrance = %Opening{
      zone_id: "moes-tavern",
      side: :south,
      align: :start,
      offset: 50,
      width: 150,
      kind: :door
    }

    centred = %Opening{zone_id: "moes-tavern", side: :west, align: :center, width: 100}

    openings = Layout.resolve(plan([@tavern], openings: [entrance, centred])).openings

    assert [
             %{level_id: "springfield", axis: :horizontal, x: 300, y: 400},
             %{axis: :vertical, x: 100, y: 200}
           ] = openings

    assert {:horizontal, 400, 300, 450} == Opening.segment(hd(openings))
  end

  test "unresolvable anchors are reported and laid out at the origin" do
    lost = %{back_room(:north, :start, 0) | anchor: %Anchor{zone_id: "kwik-e-mart", side: :north}}

    assert [{"back-room", "Back room: anchored to unknown room kwik-e-mart"}] =
             Layout.errors(plan([@tavern, lost]))

    assert %{rectangles: [%{x: 0, y: 0}]} = placed([@tavern, lost], "back-room")

    looping = %{
      @tavern
      | anchor: %Anchor{zone_id: "back-room", side: :south},
        rectangles: [%Rectangle{width: 400, depth: 300}]
    }

    errors = Layout.errors(plan([looping, back_room(:north, :start, 0)]))
    assert Enum.all?(errors, fn {_zone_id, message} -> message =~ "cycle" end)
    assert 2 == length(errors)

    elsewhere = %{back_room(:north, :start, 0) | level_id: "shelbyville"}

    assert [{"back-room", "Back room: anchored to Moe's Tavern, on another level"}] =
             Layout.errors(plan([@tavern, elsewhere]))
  end

  test "wall positions round trip" do
    wall = WallPosition.wall(hd(@tavern.rectangles), :south)

    for align <- [:start, :end] do
      offset = WallPosition.offset_for(wall, :south, align, 220, 90)
      assert 220 == WallPosition.low_coordinate(wall, :south, align, offset, 90)
    end

    assert nil == WallPosition.offset_for(wall, :south, :center, 220, 90)
  end

  describe "the example home" do
    setup do
      {:ok, snapshot} = YamlDirectory.load(path: @examples)
      %{plan: hd(snapshot.plans)}
    end

    test "anchored rooms, openings and devices are laid out", %{plan: plan} do
      resolved = Layout.resolve(plan)
      zone = &Enum.find(resolved.zones, fn zone -> zone.id == &1 end)

      assert [%{x: 500, y: 0}, %{x: 0, y: 400, width: 1000}] = zone.("studio").rectangles
      assert [%{x: 100, y: -250}] = zone.("salle-de-bain").rectangles
      assert [%{x: 1000, y: 400}] = zone.("chambre-bebe").rectangles
      assert %{x: 300, y: 600} = Enum.find(resolved.placements, &(&1.device_id == "t480s"))

      assert [
               {:vertical, 500, 100, 190},
               {:horizontal, 400, 1200, 1320},
               {:horizontal, 800, 800, 950},
               {:horizontal, 0, 210, 290}
             ] == Enum.map(resolved.openings, &Opening.segment/1)
    end

    test "is stored with anchors and sizes only", %{plan: plan} do
      encoded = Codec.encode(plan)
      studio = Enum.find(encoded["zones"], &(&1["id"] == "studio"))
      assert %{"zone_id" => "bureau-nicolas", "side" => "east"} = studio["anchor"]
      assert [%{"width" => 500, "depth" => 400} = first | _rest] = studio["rectangles"]
      refute Map.has_key?(first, "x")
      refute Map.has_key?(encoded, "resolved")
      refute Enum.any?(encoded["openings"], &Map.has_key?(&1, "x"))
    end
  end

  describe "the former absolute format" do
    test "loads: root rectangles stay absolute, openings move onto the wall holding them" do
      params = %{
        "id" => "evergreen",
        "name" => "Evergreen",
        "levels" => [%{"id" => "basement", "name" => "Basement"}],
        "zones" => [
          %{
            "id" => "rumpus",
            "name" => "Rumpus",
            "level_id" => "basement",
            "rectangles" => [
              %{"x" => 0, "y" => 0, "width" => 400, "depth" => 300},
              %{"x" => 0, "y" => 300, "width" => 200, "depth" => 200}
            ]
          }
        ],
        "openings" => [
          %{
            "level_id" => "basement",
            "axis" => "horizontal",
            "x" => 100,
            "y" => 0,
            "width" => 90
          },
          %{"level_id" => "basement", "axis" => "vertical", "x" => 999, "y" => 0, "width" => 90}
        ]
      }

      assert {:ok, plan} = Codec.decode(:plans, params)
      assert [%{x: 0, y: 300}] = tl(hd(plan.zones).rectangles)

      assert [
               %Opening{zone_id: "rumpus", side: :north, align: :start, offset: 100, x: nil},
               %Opening{zone_id: nil, x: 999}
             ] = plan.openings

      assert [{:horizontal, 0, 100, 190}, {:vertical, 999, 0, 90}] ==
               Enum.map(Layout.resolve(plan).openings, &Opening.segment/1)
    end
  end
end
