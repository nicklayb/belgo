defmodule BelgoWeb.PagesTest do
  use BelgoWeb.ConnCase

  alias Belgo.Inventory
  alias Belgo.Inventory.Snapshot

  test "every page renders", %{conn: conn} do
    for path <-
          ~w(/ /devices /devices/new /devices/smithers /devices/smithers/edit /locations /locations/new /locations/evergreen-terrace /locations/basement/edit /hosting /routing /networks /networks/new /networks/springfield/edit /sync) do
      assert {:ok, _view, html} = live(conn, path), "#{path} did not render"
      assert html =~ "Belgo"
    end
  end

  test "the health check needs no authentication", %{conn: conn} do
    assert "ok" ==
             conn
             |> get(~p"/health")
             |> text_response(200)
  end

  test "the device page pings the device and pings again on click", %{conn: conn} do
    Belgo.Reachability.subscribe("burns-node")
    {:ok, view, _html} = live(conn, ~p"/devices/burns-node")

    # A recent result (from an earlier test) is reused without pinging again.
    if match?(%{state: :pending}, Belgo.Reachability.status("burns-node")),
      do: assert_receive({:reachability_changed, %{state: :up}}, 1_000)

    render(view)
    assert has_element?(view, ~s(#reachability[data-state="up"]))

    view
    |> element("#reachability")
    |> render_click()

    assert_receive {:reachability_changed, %{state: :pending}}, 1_000
    assert_receive {:reachability_changed, %{state: :up}}, 1_000
    render(view)
    assert has_element?(view, ~s(#reachability[data-state="up"]))
  end

  test "a device that does not answer is shown as down", %{conn: conn} do
    Belgo.Reachability.subscribe("smithers")
    {:ok, view, _html} = live(conn, ~p"/devices/smithers")

    if match?(%{state: :pending}, Belgo.Reachability.status("smithers")),
      do: assert_receive({:reachability_changed, %{state: :down}}, 1_000)

    render(view)
    assert has_element?(view, ~s(#reachability[data-state="down"]))
  end

  test "the device page shows where a guest physically is", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/itchy")

    assert html =~ "Basement"
    assert html =~ "Burns Node"
    assert html =~ "Smithers"
  end

  test "the device list filters by text", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices")

    html =
      view
      |> element("#device-filter")
      |> render_change(%{"query" => "10.0.0.11"})

    assert html =~ "Smithers"
    refute html =~ "Lisa Laptop"
    assert_patch(view, "/devices?query=10.0.0.11")
  end

  test "the device list filter is restored from the URL", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/devices?kinds=laptop")

    assert html =~ "Lisa Laptop"
    refute html =~ "Smithers"

    assert has_element?(
             view,
             ~s(#kind-filter button[phx-value-kind="laptop"][aria-pressed="true"])
           )
  end

  test "kind boxes show the kinds in use with their count and filter by several kinds",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices")

    assert has_element?(view, ~s(#kind-filter button[phx-value-kind="server"]), "2")
    refute has_element?(view, ~s(#kind-filter button[phx-value-kind="printer"]))

    html = render_click(view, "toggle-kind", %{"kind" => "laptop"})
    assert_patch(view, "/devices?kinds=laptop")
    assert html =~ "Lisa Laptop"
    refute html =~ "Bart Console"

    html = render_click(view, "toggle-kind", %{"kind" => "media"})
    assert_patch(view, "/devices?kinds=laptop%2Cmedia")
    assert html =~ "Lisa Laptop"
    assert html =~ "Bart Console"
    refute html =~ "Smithers"

    html = render_click(view, "clear-kinds", %{})
    assert_patch(view, "/devices")
    assert html =~ "Smithers"
  end

  test "several devices can be edited at once, conflicts overwritten", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices?query=s")

    render_click(view, "toggle-select", %{"id" => "smithers"})
    render_click(view, "toggle-select", %{"id" => "itchy"})

    assert view
           |> element("#device-selection a", "Edit")
           |> render_click()
           |> follow_redirect(conn)
           |> then(fn {:ok, _view, html} -> html =~ "2 devices" end)

    {:ok, view, _html} = live(conn, ~p"/devices/bulk-edit?ids=itchy,smithers&query=s")

    render_change(view, "validate", %{
      "bulk_edit" => %{"placement" => "location", "metadata_sort" => ["new"]}
    })

    assert {:error, {:live_redirect, %{to: "/devices?query=s"}}} =
             view
             |> form("#bulk-edit-form",
               bulk_edit: %{
                 kind: "appliance",
                 placement: "location",
                 location_id: "living-room",
                 metadata: %{"0" => %{label: "brand", value: "Krusty"}}
               }
             )
             |> render_submit()

    for id <- ["itchy", "smithers"] do
      assert {:ok, device} = Snapshot.fetch(Inventory.snapshot(), :devices, id)
      assert %{kind: :appliance, location_id: "living-room", host_id: nil} = device
      assert [%{label: "Brand", value: "Krusty"}] = device.metadata
    end
  end

  test "creating a device saves it and shows it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices/new")

    view
    |> form("#device-form", device: %{name: "Duff Fridge", kind: "iot", placement: "location"})
    |> render_change()

    assert {:error, {:live_redirect, %{to: "/devices/duff-fridge"}}} =
             view
             |> form("#device-form",
               device: %{
                 name: "Duff Fridge",
                 kind: "iot",
                 placement: "location",
                 location_id: "living-room"
               }
             )
             |> render_submit()

    assert {:ok, %{location_id: "living-room"}} =
             Snapshot.fetch(Inventory.snapshot(), :devices, "duff-fridge")
  end

  test "invalid devices show their errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices/new")

    view
    |> form("#device-form", device: %{name: "Duff Fridge", placement: "host"})
    |> render_change()

    html =
      view
      |> form("#device-form", device: %{name: "Duff Fridge", placement: "host"})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
  end

  test "deleting a referenced location is refused with an explanation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/locations")

    html = render_click(view, "delete", %{"id" => "basement"})

    assert html =~ "Still used by"
    assert {:ok, _basement} = Snapshot.fetch(Inventory.snapshot(), :locations, "basement")
  end

  test "a location page lists every device inside it, sub-locations included", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/locations/evergreen-terrace")

    for name <- ["Burns Node", "Itchy", "Plow King", "Power Plant", "Smithers", "TV"] do
      assert html =~ name
    end

    refute html =~ "Lisa"
    assert html =~ "on Burns Node › Smithers"
    assert has_element?(view, ~s(a[href="/locations/basement"]))

    {:ok, _view, html} = live(conn, ~p"/locations/living-room")
    assert html =~ "Here"
    assert html =~ ~s(href="/locations/evergreen-terrace")
  end

  test "an empty location can be deleted from its page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/locations/new?parent_id=basement")

    view
    |> form("#location-form", location: %{name: "Moe's Cellar"})
    |> render_submit()

    {:ok, view, html} = live(conn, ~p"/locations/moes-cellar")
    assert html =~ "No device here"

    assert {:error, {:live_redirect, %{to: "/locations"}}} = render_click(view, "delete", %{})
    assert {:error, :not_found} = Snapshot.fetch(Inventory.snapshot(), :locations, "moes-cellar")
  end

  test "the hosting page groups hosts by platform", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/hosting")

    assert has_element?(view, "#platform-proxmox", "Burns Node")
    assert has_element?(view, "#platform-proxmox", "Smithers")
    assert has_element?(view, "#platform-docker", "Itchy")
    assert has_element?(view, "#platform-docker", "Virtual machine on Burns Node")
    refute has_element?(view, "#platform-proxmox", "Itchy")
  end

  test "pages follow inventory changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/hosting")

    {:ok, _location} =
      Inventory.create(:devices, %{"name" => "Krusty Box", "platforms" => ["docker"]},
        user: :system
      )

    assert render(view) =~ "Krusty Box"
  end

  test "the routing page shows the tree from the gateway", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/routing")

    assert html =~ "Power Plant"
    assert html =~ "Plow King"
    assert html =~ "New switch"
  end

  test "an unmanaged switch can be created from the routing page", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/devices/new?kind=network&network_role=switch")

    assert html =~ "Role in the network"

    assert html =~ "Plugged into"

    assert {:error, {:live_redirect, %{to: "/devices/attic-switch"}}} =
             view
             |> form("#device-form",
               device: %{
                 name: "Attic Switch",
                 placement: "unplaced",
                 uplink_id: "plow-king",
                 uplink_port: "8"
               }
             )
             |> render_submit()

    assert {:ok,
            %{
              kind: :network,
              network_role: :switch,
              uplink_id: "plow-king",
              uplink_port: "8",
              interfaces: []
            }} =
             Snapshot.fetch(Inventory.snapshot(), :devices, "attic-switch")

    {:ok, _view, html} = live(conn, ~p"/routing")
    assert html =~ "Attic Switch"
  end

  test "a device page shows its network path", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/devices/plow-king")

    assert html =~ "Connected to"
    assert html =~ "Power Plant"
  end

  test "metadata can be added to a device and is shown", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices/plow-king/edit")

    html = render_click(view, "validate", %{"device" => %{"metadata_sort" => ["new"]}})
    assert html =~ "metadata-labels"
    assert has_element?(view, ~s(#metadata-labels option[value="Serial number"]))

    assert {:error, {:live_redirect, %{to: "/devices/plow-king"}}} =
             view
             |> form("#device-form",
               device: %{metadata: %{"0" => %{label: "bRAND", value: "Mr. Plow"}}}
             )
             |> render_submit()

    assert {:ok, %{metadata: [%{label: "Brand", value: "Mr. Plow"}]}} =
             Snapshot.fetch(Inventory.snapshot(), :devices, "plow-king")

    {:ok, _view, html} = live(conn, ~p"/devices/plow-king")
    assert html =~ "Mr. Plow"
  end

  test "adding a metadata entry keeps the entries being typed in place", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices/plow-king/edit")
    brand = %{"_persistent_id" => "0", "label" => "brand", "value" => "Apple"}

    # The Add button sits above the entries, so the browser sends "new" first.
    html =
      render_change(view, "validate", %{
        "device" => %{"metadata_sort" => ["new", "0"], "metadata" => %{"0" => brand}}
      })

    assert ["brand", ""] == metadata_labels(html)

    html =
      render_change(view, "validate", %{
        "device" => %{
          "metadata_sort" => ["0", "1"],
          "metadata" => %{
            "0" => brand,
            "1" => %{"_persistent_id" => "1", "label" => "Model", "value" => "M"}
          }
        }
      })

    assert ["Brand", "Model"] == metadata_labels(html)

    assert ["0", "1"] ==
             html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("input[name^='device[metadata]'][name$='[_persistent_id]']")
             |> LazyHTML.attribute("value")
  end

  test "metadata values are suggested from the values used with the same label", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices/plow-king/edit")

    html =
      render_change(view, "validate", %{
        "device" => %{
          "metadata_sort" => ["0", "new"],
          "metadata" => %{"0" => %{"label" => "brand", "value" => ""}}
        }
      })

    document = LazyHTML.from_fragment(html)

    [brand_list, new_list] =
      document
      |> LazyHTML.query("input[name^='device[metadata]'][name$='[value]']")
      |> LazyHTML.attribute("list")

    assert ["Excellent Computers"] ==
             document
             |> LazyHTML.query("datalist##{brand_list} option")
             |> LazyHTML.attribute("value")

    assert "metadata-values-all" == new_list

    # Only the just added entry (no label yet) takes the focus when it appears.
    assert [_new_label] =
             document
             |> LazyHTML.query("input[name^='device[metadata]'][name$='[label]'][phx-mounted]")
             |> Enum.to_list()
  end

  defp metadata_labels(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("input[name^='device[metadata]'][name$='[label]']")
    |> Enum.map(&label_value/1)
  end

  defp label_value(input) do
    case LazyHTML.attribute(input, "value") do
      [value] -> value
      [] -> ""
    end
  end

  test "the search modal opens and finds devices", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#search-input")

    view
    |> with_target("#global-search")
    |> render_click("open", %{})

    assert has_element?(view, "#search-input")

    html =
      view
      |> form("#global-search form", search: %{query: "SN-1895"})
      |> render_change()

    assert html =~ "Burns Node"
    assert html =~ "Serial number"

    view
    |> with_target("#global-search")
    |> render_click("close", %{})

    refute has_element?(view, "#search-input")
  end
end
