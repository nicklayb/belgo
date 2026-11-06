defmodule BelgoWeb.PlanEditorTest do
  use BelgoWeb.ConnCase

  alias Belgo.Inventory
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
    assert [%{kind: :door, axis: :vertical, x: 500}] = plan.openings

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

    render_click(element(view, "#plan-warnings button", "Anchor"))
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
    render_change(form(view, "#plan-place-device form", %{"device_id" => "burns-node"}))
    render_hook(view, "place", %{"x" => 900, "y" => 200})

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

    send(view.pid, :autosave)
    assert has_element?(view, "#plan-save-status[data-status=saved]")

    assert [%{device_id: "burns-node", anchor: :wall, height: 180}] =
             saved_plan("742-evergreen-terrace").placements

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
  end

  test "the drawn grid follows the snapping step", %{conn: conn} do
    view = create_home(conn)
    assert has_element?(view, "#plan-grid-step[width='10']")

    render_change(form(view, "#plan-editor-toolbar-grid", grid: "100"))
    assert has_element?(view, "#plan-grid-step[width='100']")
    assert has_element?(view, "#plan-editor[data-grid='100']")
  end
end
