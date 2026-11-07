defmodule BelgoWeb.PlanEditorTest do
  use BelgoWeb.ConnCase

  alias Belgo.Inventory
  alias Belgo.Inventory.Codec
  alias Belgo.Inventory.Snapshot

  defp saved_plan(id) do
    {:ok, plan} = Snapshot.fetch(Inventory.snapshot(), :plans, id)
    plan
  end

  defp create_home(conn) do
    {:ok, view, _html} = live(conn, ~p"/plan/new")

    view
    |> form("#new-plan", plan: %{name: "742 Evergreen Terrace"})
    |> render_submit()

    assert_patch(view, ~p"/plan/742-evergreen-terrace/edit")
    view
  end

  test "a new home is saved right away", %{conn: conn} do
    create_home(conn)
    assert %{name: "742 Evergreen Terrace", levels: []} = saved_plan("742-evergreen-terrace")
  end

  test "draw levels and rooms, saved by the autosave", %{conn: conn} do
    view = create_home(conn)

    render_submit(form(view, "#add-level", level: %{name: "Basement"}))
    render_hook(view, "tool", %{"tool" => "draw"})
    render_hook(view, "draw", %{"x" => 0, "y" => 0, "width" => 800, "depth" => 400})

    assert has_element?(view, "#plan-save-status[data-status=pending]")
    assert has_element?(view, "#plan-selected-zone")

    send(view.pid, :autosave)
    assert has_element?(view, "#plan-save-status[data-status=saved]")

    assert %{zones: [%{name: "Room 1", level_id: "basement"}]} =
             saved_plan("742-evergreen-terrace")

    # Split it, then add a door on the new wall.
    render_hook(view, "tool", %{"tool" => "split"})
    render_hook(view, "split", %{"zone_id" => "room-1", "x" => 500, "y" => 100})
    render_hook(view, "tool", %{"tool" => "door"})
    render_hook(view, "add-opening", %{"x" => 505, "y" => 200})
    assert has_element?(view, "#plan-selected-opening")

    # A level stacked on the basement copies its footprint.
    view
    |> form("#add-level",
      level: %{name: "Ground floor", base_id: "basement", offset: "1.0", copy: "true"}
    )
    |> render_submit()

    render_click(element(view, "#plan-done"))
    assert_redirect(view, ~p"/plan/742-evergreen-terrace")

    plan = saved_plan("742-evergreen-terrace")
    assert ["Room 1", "Room 2", "Ground floor"] == Enum.map(plan.zones, & &1.name)
    # The door belongs to the wall of Room 1 it was put on; Room 2 is anchored there.
    assert [%{kind: :door, zone_id: "room-1", side: :east, align: :start, offset: 155}] =
             plan.openings

    assert %{anchor: %{zone_id: "room-1", side: :east}} =
             Enum.find(plan.zones, &(&1.id == "room-2"))

    assert %{base_id: "basement", offset: 1.0} =
             Enum.find(plan.levels, &(&1.id == "ground-floor"))
  end

  test "moving a room out of the home warns and offers to anchor it", %{conn: conn} do
    view = create_home(conn)
    render_submit(form(view, "#add-level", level: %{name: "Basement"}))
    render_hook(view, "tool", %{"tool" => "draw"})
    render_hook(view, "draw", %{"x" => 0, "y" => 0, "width" => 800, "depth" => 400})
    render_hook(view, "tool", %{"tool" => "draw"})
    render_hook(view, "draw", %{"x" => 800, "y" => 0, "width" => 200, "depth" => 200})

    render_hook(view, "move", %{
      "zone_id" => "room-2",
      "index" => 0,
      "whole" => true,
      "delta_x" => 1000,
      "delta_y" => 0
    })

    assert has_element?(view, "#plan-warnings [data-warning=orphan_zone]")
    # Anchoring is optional (owner): a room drawn on its own is not reported.
    refute has_element?(view, "#plan-warnings [data-warning=unanchored_zone]")

    render_click(element(view, "#plan-warnings button[phx-click=anchor]"))
    refute has_element?(view, "#plan-warnings [data-warning=orphan_zone]")
  end

  test "an invalid plan is not saved and says why", %{conn: conn} do
    view = create_home(conn)
    render_submit(form(view, "#add-level", level: %{name: "Basement"}))
    render_hook(view, "tool", %{"tool" => "draw"})
    render_hook(view, "draw", %{"x" => 0, "y" => 0, "width" => 400, "depth" => 400})
    render_hook(view, "tool", %{"tool" => "draw"})
    render_hook(view, "draw", %{"x" => 200, "y" => 200, "width" => 400, "depth" => 400})

    send(view.pid, :autosave)
    assert has_element?(view, "#plan-save-status[data-status=error]", "Room 1 and Room 2 overlap")
  end

  defp home_with_rooms(conn) do
    view = create_home(conn)
    render_submit(form(view, "#add-level", level: %{name: "Basement"}))
    render_hook(view, "tool", %{"tool" => "draw"})
    render_hook(view, "draw", %{"x" => 0, "y" => 0, "width" => 800, "depth" => 400})
    render_hook(view, "tool", %{"tool" => "draw"})
    render_hook(view, "draw", %{"x" => 800, "y" => 0, "width" => 200, "depth" => 400})
    view
  end

  test "undo and redo the last edits, delete the selection", %{conn: conn} do
    view = home_with_rooms(conn)
    assert has_element?(view, "#plan-editor-canvas g[data-zone=room-2]")

    render_hook(view, "key", %{"action" => "undo"})
    refute has_element?(view, "#plan-editor-canvas g[data-zone=room-2]")

    render_hook(view, "key", %{"action" => "redo"})
    assert has_element?(view, "#plan-editor-canvas g[data-zone=room-2]")

    render_hook(view, "select-zone", %{"zone_id" => "room-2", "index" => 0})
    render_hook(view, "key", %{"action" => "delete"})
    refute has_element?(view, "#plan-editor-canvas g[data-zone=room-2]")
  end

  test "the tree hides rooms and shows other levels underneath", %{conn: conn} do
    view = home_with_rooms(conn)
    assert has_element?(view, ~s(#plan-tree [data-tree="zone:room-1"]))
    assert has_element?(view, ~s(#plan-tree [data-tree="rectangle:room-1:0"]), "800 × 400")

    render_click(element(view, ~s(#plan-tree [data-tree="zone:room-1"] button[data-eye])))
    refute has_element?(view, "#plan-editor-canvas g[data-zone=room-1]")
    assert has_element?(view, ~s(#plan-tree [data-tree="zone:room-1"] [data-eye=off]))

    # The exterior shows the basement underneath once its eye is on.
    render_click(
      element(view, ~s(#plan-tree [data-tree="level:exterior"] button[phx-click=focus]))
    )

    refute has_element?(view, "#plan-editor-canvas [data-ghosts]")
    render_click(element(view, ~s(#plan-tree [data-tree="level:basement"] button[data-eye])))
    assert has_element?(view, "#plan-editor-canvas [data-ghosts]")
  end

  test "dimensions are typed in the room panel", %{conn: conn} do
    view = home_with_rooms(conn)

    render_click(
      element(view, ~s(#plan-tree [data-tree="rectangle:room-1:0"] button[phx-click=focus]))
    )

    assert has_element?(view, "#rectangle-0.ring-accent")

    view
    |> form("#rectangle-0", rectangle: %{x: "0", y: "0", width: "650", depth: "400"})
    |> render_change()

    assert has_element?(view, ~s(#plan-tree [data-tree="rectangle:room-1:0"]), "650 × 400")
  end

  test "places a device, anchors it and aligns its location with the room", %{conn: conn} do
    view = home_with_rooms(conn)

    view
    |> form("#zone-form", zone: %{name: "Room 2", location_id: "living-room"})
    |> render_change()

    render_hook(view, "tool", %{"tool" => "place"})
    assert has_element?(view, "#plan-place-device")

    # Grouped by the devices' locations.
    assert has_element?(
             view,
             ~s(#plan-place-device-select optgroup[label="742 Evergreen Terrace › Basement"] option[value="burns-node"])
           )

    # Guests are where their host is: not offered, refused.
    refute has_element?(view, ~s(#plan-place-device-select option[value="itchy"]))
    render_hook(view, "choose-device", %{"device_id" => "itchy"})
    render_hook(view, "place", %{"x" => 900, "y" => 200})
    refute has_element?(view, ~s(#plan-editor-canvas [data-placement="itchy"]))

    render_change(form(view, "#plan-place-device form", %{"device_id" => "burns-node"}))
    render_hook(view, "place", %{"x" => 900, "y" => 200})

    # Placed: no longer offered, listed under Elements.
    render_hook(view, "tool", %{"tool" => "place"})
    refute has_element?(view, ~s(#plan-place-device-select option[value="burns-node"]))

    assert has_element?(
             view,
             ~s(#plan-placed-devices [data-placed-device="burns-node"]),
             "Burns Node"
           )

    render_hook(view, "tool", %{"tool" => "select"})
    render_click(element(view, ~s(#plan-placed-devices [data-placed-device="burns-node"])))

    assert has_element?(view, "#plan-selected-placement", "Burns Node")
    assert has_element?(view, ~s(#plan-editor-canvas [data-placement="burns-node"]))
    assert has_element?(view, ~s(#plan-tree [data-tree="placement:burns-node"]))

    # Burns Node is in the basement, the room is the living room.
    assert has_element?(view, "#plan-warnings [data-warning=location_mismatch]")
    render_click(element(view, "#plan-warnings button", "Set location"))
    {:ok, device} = Snapshot.fetch(Inventory.snapshot(), :devices, "burns-node")
    assert "living-room" == device.location_id

    render_change(form(view, "#plan-selected-placement form", placement: %{anchor: "wall"}))
    render_change(form(view, "#plan-selected-placement form", placement: %{height: "180"}))
    refute has_element?(view, "#plan-editor-canvas [data-device-box]")

    # Typed one field at a time: the fields already filled keep their value.
    view
    |> form("#plan-selected-placement form", placement: %{shape: %{width: "60"}})
    |> render_change()

    assert has_element?(
             view,
             ~s(#placement-shape input[name="placement[shape][width]"][value="60"])
           )

    refute has_element?(view, "#plan-editor-canvas [data-device-box]")

    view
    |> form("#plan-selected-placement form",
      placement: %{shape: %{width: "60", depth: "40", height: "200"}}
    )
    |> render_change()

    assert has_element?(view, "#plan-editor-canvas [data-device-box]")

    send(view.pid, :autosave)
    assert has_element?(view, "#plan-save-status[data-status=saved]")

    assert [
             %{
               device_id: "burns-node",
               anchor: :wall,
               height: 180,
               shape: %{width: 60, depth: 40, height: 200}
             }
           ] = saved_plan("742-evergreen-terrace").placements

    view
    |> form("#plan-selected-placement form",
      placement: %{shape: %{width: "", depth: "", height: ""}}
    )
    |> render_change()

    refute has_element?(view, "#plan-editor-canvas [data-device-box]")

    render_hook(view, "key", %{"action" => "delete"})
    refute has_element?(view, ~s(#plan-editor-canvas [data-placement="burns-node"]))
  end

  test "a + on a free side adds a room along it", %{conn: conn} do
    view = home_with_rooms(conn)

    # Room 1 (0..800) touches Room 2 on its east side only.
    refute has_element?(view, ~s([data-extend="room-1"][data-side=east]))
    assert has_element?(view, ~s([data-extend="room-1"][data-side=north]))

    index =
      view
      |> element(~s([data-extend="room-1"][data-side=south]))
      |> render()
      |> then(&Regex.run(~r/data-side-index="(\d+)"/, &1, capture: :all_but_first))
      |> hd()
      |> String.to_integer()

    render_hook(view, "extend-room", %{"zone_id" => "room-1", "index" => index})
    assert has_element?(view, ~s(#plan-tree [data-tree="rectangle:room-3:0"]), "800 × 300")
    refute has_element?(view, ~s([data-extend="room-1"][data-side=south]))

    # It is anchored to Room 1: selected, never dragged; aligned in its panel.
    assert has_element?(view, ~s(#plan-tree [data-tree="zone:room-3"]), "on Room 1")
    assert has_element?(view, ~s(#plan-editor-canvas rect[data-zone="room-3"][data-anchored]))
    assert has_element?(view, "#plan-zone-anchor", "south wall of Room 1")

    render_hook(view, "move", %{
      "zone_id" => "room-3",
      "index" => 0,
      "whole" => true,
      "delta_x" => 100,
      "delta_y" => 0
    })

    assert render(view) =~ "Room 3 is anchored"
    assert has_element?(view, ~s(#plan-editor-canvas rect[data-zone="room-3"][x="0"][y="400"]))

    view
    |> form("#anchor-form", anchor: %{previous_align: "start", align: "start", offset: "100"})
    |> render_change()

    send(view.pid, :autosave)
    assert has_element?(view, "#plan-save-status[data-status=saved]")

    assert %{anchor: %{side: :south, align: :start, offset: 100}, rectangles: [%{x: nil}]} =
             Enum.find(saved_plan("742-evergreen-terrace").zones, &(&1.id == "room-3"))
  end

  test "anchoring a room by hand, orphans when its parent is deleted", %{conn: conn} do
    view = home_with_rooms(conn)

    # Room 2 was drawn on its own: no warning, its panel offers to anchor it.
    refute has_element?(view, "#plan-warnings [data-warning=unanchored_zone]")
    render_hook(view, "select-zone", %{"zone_id" => "room-2", "index" => 0})
    assert has_element?(view, "#plan-zone-anchoring")

    view
    |> form("#anchor-to-form", anchor: %{own: "0:west", target: "room-1/0:east"})
    |> render_submit()

    assert has_element?(view, "#plan-zone-anchor", "east wall of Room 1")

    # Resizing Room 1 moves Room 2 with it.
    render_hook(view, "set-rectangle", %{
      "zone_id" => "room-1",
      "index" => 0,
      "x" => 0,
      "y" => 0,
      "width" => 600,
      "depth" => 400
    })

    assert has_element?(view, ~s(#plan-editor-canvas rect[data-zone="room-2"][x="600"]))

    # A third room on Room 1's south side, then Room 1 goes: both stay where they
    # were, as roots (no warning), and Room 3 can be anchored again.
    index =
      view
      |> element(~s([data-extend="room-1"][data-side=south]))
      |> render()
      |> then(&Regex.run(~r/data-side-index="(\d+)"/, &1, capture: :all_but_first))
      |> hd()
      |> String.to_integer()

    render_hook(view, "extend-room", %{"zone_id" => "room-1", "index" => index})
    render_hook(view, "select-zone", %{"zone_id" => "room-1", "index" => 0})
    render_click(element(view, "#plan-selected-zone button[phx-click=delete-zone]"))

    assert has_element?(view, ~s(#plan-editor-canvas rect[data-zone="room-2"][x="600"]))
    assert has_element?(view, ~s(#plan-editor-canvas rect[data-zone="room-3"][y="400"]))
    refute has_element?(view, "#plan-warnings [data-warning=unanchored_zone]")
    render_hook(view, "select-zone", %{"zone_id" => "room-3", "index" => 0})
    assert has_element?(view, "#plan-zone-anchoring")
  end

  test "a door is aligned on its wall in its panel", %{conn: conn} do
    view = home_with_rooms(conn)
    render_hook(view, "tool", %{"tool" => "door"})
    render_hook(view, "add-opening", %{"x" => 400, "y" => 5})
    assert has_element?(view, "#plan-opening-wall", "north wall of Room 1")

    view
    |> form("#plan-selected-opening form",
      opening: %{previous_align: "start", align: "center", offset: "355"}
    )
    |> render_change()

    send(view.pid, :autosave)
    assert has_element?(view, "#plan-save-status[data-status=saved]")

    assert [%{zone_id: "room-1", side: :north, align: :center, offset: nil, width: 90}] =
             saved_plan("742-evergreen-terrace").openings
  end

  test "the drawn grid follows the snapping step", %{conn: conn} do
    view = create_home(conn)
    assert has_element?(view, "#plan-grid-step[width='10']")

    render_change(form(view, "#plan-editor-toolbar-grid", grid: "100"))
    assert has_element?(view, "#plan-grid-step[width='100']")
    assert has_element?(view, "#plan-editor[data-grid='100']")
  end

  test "the home panel explains where the ground is", %{conn: conn} do
    view = create_home(conn)
    render_submit(form(view, "#add-level", level: %{name: "Basement"}))
    assert has_element?(view, "#plan-ground-summary", "Not set")

    view
    |> form("#plan-settings form", settings: %{ground_level_id: "basement", ground_percent: "80"})
    |> render_change()

    assert has_element?(view, "#plan-ground-summary", "Ground at 2.16 m, 80 % up Basement.")
    assert has_element?(view, "#plan-ground-summary", "Draw the terrain on the Exterior tab")
  end

  test "each level has its own height and wall height", %{conn: conn} do
    view = create_home(conn)
    render_submit(form(view, "#add-level", level: %{name: "Basement"}))
    render_submit(form(view, "#add-level", level: %{name: "Ground floor", base_id: "basement"}))

    view
    |> form("#level-form-basement", level: %{height: "220", wall_height: "200"})
    |> render_change()

    assert has_element?(view, "#plan-levels-panel", "2.20 m")

    send(view.pid, :autosave)
    assert has_element?(view, "#plan-save-status[data-status=saved]")

    assert [%{id: "basement", height: 220, wall_height: 200}, %{id: "ground-floor", height: nil}] =
             saved_plan("742-evergreen-terrace").levels
  end

  test "a hosted device on the plan is warned about and can be removed", %{conn: conn} do
    view = home_with_rooms(conn)
    render_hook(view, "tool", %{"tool" => "place"})
    render_change(form(view, "#plan-place-device form", %{"device_id" => "burns-node"}))
    render_hook(view, "place", %{"x" => 300, "y" => 200})
    send(view.pid, :autosave)
    assert has_element?(view, "#plan-save-status[data-status=saved]")

    # Placed before it became a guest (e.g. by hand in plans.yaml).
    plan = saved_plan("742-evergreen-terrace")
    itchy = %{hd(plan.placements) | device_id: "itchy"}

    {:ok, _plan} =
      Inventory.update(:plans, plan.id, Codec.encode(%{plan | placements: [itchy]}),
        user: :system
      )

    {:ok, view, _html} = live(conn, ~p"/plan/742-evergreen-terrace/edit")
    assert has_element?(view, "#plan-warnings [data-warning=hosted_device]", "Smithers")
    render_click(element(view, "#plan-warnings button", "Remove from plan"))
    refute has_element?(view, "#plan-warnings [data-warning=hosted_device]")
  end
end
