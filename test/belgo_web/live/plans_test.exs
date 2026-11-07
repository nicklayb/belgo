defmodule BelgoWeb.PlansTest do
  use BelgoWeb.ConnCase

  alias Belgo.Inventory

  @evergreen_terrace %{
    "id" => "evergreen-terrace",
    "name" => "742 Evergreen Terrace",
    "location_id" => "evergreen-terrace",
    "ground" => %{"level_id" => "basement", "percent" => 80},
    "levels" => [
      %{"id" => "basement", "name" => "Basement", "offset" => 0},
      %{"id" => "ground-floor", "name" => "Ground floor", "base_id" => "basement", "offset" => 1}
    ],
    "zones" => [
      %{
        "id" => "living-room",
        "name" => "Living Room",
        "level_id" => "ground-floor",
        "location_id" => "living-room",
        "rectangles" => [%{"x" => 0, "y" => 0, "width" => 500, "depth" => 400}]
      },
      %{
        "id" => "kitchen",
        "name" => "Kitchen",
        "level_id" => "ground-floor",
        "rectangles" => [%{"x" => 500, "y" => 0, "width" => 300, "depth" => 400}]
      },
      %{
        "id" => "basement-room",
        "name" => "Basement",
        "level_id" => "basement",
        "location_id" => "basement",
        "rectangles" => [%{"x" => 0, "y" => 0, "width" => 800, "depth" => 400}]
      },
      %{
        "id" => "backyard",
        "name" => "Backyard",
        "rectangles" => [%{"x" => -200, "y" => -200, "width" => 1200, "depth" => 1000}]
      }
    ],
    "openings" => [
      %{
        "level_id" => "ground-floor",
        "x" => 500,
        "y" => 100,
        "axis" => "vertical",
        "width" => 90,
        "kind" => "door"
      }
    ],
    "placements" => [
      %{
        "device_id" => "tv-living-room",
        "zone_id" => "living-room",
        "anchor" => "wall",
        "x" => 250,
        "y" => 0,
        "height" => 120
      },
      %{
        "device_id" => "burns-node",
        "zone_id" => "living-room",
        "anchor" => "floor",
        "x" => 100,
        "y" => 100
      }
    ]
  }

  test "without plan, explains where plans come from", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/plan")
    assert html =~ "No plan yet"
    assert html =~ ~s(href="/plan/new")
  end

  test "draws a level with its rooms, measures, door and devices", %{conn: conn} do
    {:ok, _plan} = Inventory.create(:plans, @evergreen_terrace, user: :system)
    {:ok, view, _html} = live(conn, ~p"/plan?view=2d&level=ground-floor")

    assert has_element?(view, "#plan-levels a", "Basement")
    assert has_element?(view, "#plan-levels a", "Exterior")
    assert has_element?(view, "#plan-level-ground-floor [data-zone=living-room]")
    assert has_element?(view, "[data-measure=living-room]", "5.0 × 4.0 m · 20.0 m²")
    assert has_element?(view, "[data-opening=door]")

    assert has_element?(
             view,
             ~s([data-placement=tv-living-room] a[href="/devices/tv-living-room"])
           )

    # Burns Node lives in the basement, not in the living room it is drawn in.
    assert has_element?(view, "#plan-warnings [data-warning=location_mismatch]", "Burns Node")
  end

  test "levels and the exterior are reached by their tab", %{conn: conn} do
    {:ok, _plan} = Inventory.create(:plans, @evergreen_terrace, user: :system)
    {:ok, view, _html} = live(conn, ~p"/plan/evergreen-terrace?view=2d")

    # The lowest level comes first.
    assert has_element?(view, "#plan-level-basement")

    render_click(element(view, "#plan-levels a", "Exterior"))
    assert_patch(view, ~p"/plan/evergreen-terrace?level=exterior&view=2d")
    assert has_element?(view, "#plan-level-exterior [data-zone=backyard]")
    assert has_element?(view, "#plan-level-exterior [data-footprint]")
  end

  test "shows the home in 3D by default, up to a level when chosen", %{conn: conn} do
    {:ok, _plan} = Inventory.create(:plans, @evergreen_terrace, user: :system)
    {:ok, view, _html} = live(conn, ~p"/plan")

    assert has_element?(view, ~s(#plan-3d[phx-hook="Plan3D"][data-visible-up-to=""]))

    for key <- ~w(labels names facade),
        do: assert(has_element?(view, ~s(#plan-3d button[data-toggle="#{key}"])))

    scene = scene_of(render(element(view, "#plan-3d")))
    assert Enum.any?(scene["devices"], &(&1["name"] == "TV Living Room"))
    assert Enum.any?(scene["walls"], &(&1["kind"] == "door"))

    render_click(element(view, "#plan-levels a", "Basement"))
    assert has_element?(view, ~s(#plan-3d[data-visible-up-to="0.0"]))
  end

  defp scene_of(html) do
    [_match, json] = Regex.run(~r/data-scene="([^"]*)"/, html)

    json
    |> String.replace("&quot;", "\"")
    |> String.replace("&amp;", "&")
    |> Jason.decode!()
  end

  test "a click on a device shows its network path", %{conn: conn} do
    plow_king = %{
      "device_id" => "plow-king",
      "zone_id" => "basement-room",
      "anchor" => "floor",
      "x" => 600,
      "y" => 200
    }

    plan = Map.update!(@evergreen_terrace, "placements", &[plow_king | &1])
    {:ok, _plan} = Inventory.create(:plans, plan, user: :system)
    {:ok, view, _html} = live(conn, ~p"/plan")
    refute has_element?(view, "#plan-network-path")

    render_hook(element(view, "#plan-3d"), "select-device", %{"device_id" => "burns-node"})

    assert has_element?(view, "#plan-network-path", "Burns Node")
    assert has_element?(view, "#plan-network-path", "Plow King")

    [_match, json] = Regex.run(~r/data-network-path="([^"]*)"/, render(element(view, "#plan-3d")))

    assert %{
             "device_id" => "burns-node",
             "segments" => [%{"from" => "burns-node", "to" => "plow-king", "kind" => "wired"}]
           } = Jason.decode!(String.replace(json, "&quot;", "\""))

    render_hook(element(view, "#plan-3d"), "select-device", %{"device_id" => ""})
    refute has_element?(view, "#plan-network-path")
    refute render(element(view, "#plan-3d")) =~ "data-network-path"
  end

  test "the 3D view filters devices by kind, keeping the shown path", %{conn: conn} do
    {:ok, _plan} = Inventory.create(:plans, @evergreen_terrace, user: :system)
    {:ok, view, _html} = live(conn, ~p"/plan")

    assert has_element?(view, ~s(#plan-kind-filter button[phx-value-kind="media"]))
    render_click(element(view, ~s(#plan-kind-filter button[phx-value-kind="media"])))
    assert_patch(view, ~p"/plan/evergreen-terrace?kinds=media")

    hidden =
      for device <- scene_of(render(element(view, "#plan-3d")))["devices"],
          into: %{},
          do: {device["device_id"], device["hidden"]}

    assert %{"tv-living-room" => false, "burns-node" => true} = hidden

    # Levels keep the filter.
    assert has_element?(view, ~s(#plan-levels a[href*="kinds=media"]))

    render_click(element(view, "#plan-kind-filter button", "All kinds"))
    assert_patch(view, ~p"/plan/evergreen-terrace")
  end
end
