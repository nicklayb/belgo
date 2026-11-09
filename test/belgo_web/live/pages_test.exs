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

  test "the theme of config.yaml is set on the page", %{conn: conn} do
    directory = Application.fetch_env!(:belgo, Belgo.Config)[:directory]
    path = Path.join(directory, "config.yaml")
    on_exit(fn -> File.rm(path) end)

    assert page_html(conn) =~ ~s(data-theme="auto")

    File.write!(path, "version: 1\ntheme: dark\n")
    assert page_html(conn) =~ ~s(data-theme="dark")

    File.write!(path, "version: 1\ntheme: neon\n")
    assert page_html(conn) =~ ~s(data-theme="auto")
  end

  defp page_html(conn) do
    conn
    |> get(~p"/")
    |> html_response(200)
  end

  test "the health check needs no authentication", %{conn: conn} do
    assert "ok" ==
             conn
             |> get(~p"/health")
             |> text_response(200)
  end

  # Results are shared by every test (one server per application): a recent result
  # may already exist, so the tests wait for the expected state rather than a ping.
  defp await_state(view, selector, state) do
    Enum.find_value(1..20, fn _attempt ->
      render(view)
      has_element?(view, ~s(#{selector}[data-state="#{state}"])) || (Process.sleep(50) && nil)
    end)
  end

  test "the device page pings the device and pings again on click", %{conn: conn} do
    Belgo.Reachability.subscribe()
    {:ok, view, _html} = live(conn, ~p"/devices/burns-node")
    assert await_state(view, "#reachability", "up")

    view
    |> element("#reachability")
    |> render_click()

    assert_receive {:reachability_changed, [%{address: "10.0.0.10", result: :pending}]}, 1_000
    assert await_state(view, "#reachability", "up")
  end

  test "a device that does not answer is shown as down", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices/smithers")
    assert await_state(view, "#reachability", "down")
  end

  test "the overview counts the devices that do not answer", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert await_state(view, "#devices-reachability [data-state]", "down")
    # Only Burns Node (10.0.0.10) answers among the fixture devices with an address.
    assert render(element(view, "#devices-reachability")) =~ ~r/\d+ do not answer/
  end

  test "the device list shows whether each device answers", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices")
    assert await_state(view, "#device-burns-node [data-reachability]", "up")
    assert await_state(view, "#device-smithers [data-reachability]", "down")
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

  test "the host field lists the devices able to host guests", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices/itchy/edit")
    host_option = &~s(select[name="device[host_id]"] option[value="#{&1}"])

    assert has_element?(view, host_option.("smithers"), "Smithers (Docker)")
    assert has_element?(view, host_option.("burns-node"), "Burns Node (Proxmox)")
    refute has_element?(view, host_option.("tv-living-room"))
    refute has_element?(view, host_option.("plow-king"))
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

    # Each platform has its colour: Proxmox orange, Docker pale blue.
    assert has_element?(view, ~s(#platform-proxmox [data-platform="proxmox"].text-proxmox))
    assert has_element?(view, ~s(#platform-docker [data-platform="docker"].text-docker))
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
    {:ok, view, html} = live(conn, ~p"/routing")

    assert html =~ "Power Plant"
    assert html =~ "Plow King"
    assert html =~ "New switch"
    # Other tests may plug devices into Plow King (shared inventory).
    assert render(element(view, "#ports-plow-king")) =~ ~r{\d+/8 ports}
    assert has_element?(view, "[data-poe]")
  end

  test "PoE switches have an icon in the device list and on their page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices")
    assert has_element?(view, "#device-plow-king [data-poe]")
    refute has_element?(view, "#device-burns-node [data-poe]")

    {:ok, _view, html} = live(conn, ~p"/devices/plow-king")
    assert html =~ "PoE"
    assert html =~ "8 ports"
  end

  test "an unmanaged switch can be created from the routing page", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/devices/new?kind=network&network_role=switch")

    assert html =~ "Role in the network"

    assert html =~ "Plugged into"
    assert html =~ "Number of ports"
    assert html =~ "Supplies PoE"

    assert {:error, {:live_redirect, %{to: "/devices/attic-switch"}}} =
             view
             |> form("#device-form",
               device: %{
                 name: "Attic Switch",
                 placement: "unplaced",
                 uplink_id: "plow-king",
                 uplink_port: "8",
                 port_count: "16",
                 poe: "true"
               }
             )
             |> render_submit()

    assert {:ok,
            %{
              kind: :network,
              network_role: :switch,
              uplink_id: "plow-king",
              uplink_port: "8",
              port_count: 16,
              poe: true,
              interfaces: []
            }} =
             Snapshot.fetch(Inventory.snapshot(), :devices, "attic-switch")

    {:ok, view, html} = live(conn, ~p"/routing")
    assert html =~ "Attic Switch"
    assert render(element(view, "#ports-attic-switch")) =~ "0/16 ports"
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

  test "the search dialog is opened by the browser and finds devices", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # Opening and focusing happen in the browser (SearchDialog hook), see search_dialog.js.
    assert has_element?(view, ~s(dialog#search-dialog[phx-hook="SearchDialog"]))
    assert has_element?(view, "#search-input[autofocus]")
    assert has_element?(view, "button[data-search-open]")

    html =
      view
      |> form("#global-search form", search: %{query: "SN-1895"})
      |> render_change()

    assert html =~ "Burns Node"
    assert html =~ "Serial number"
  end

  test "the device page lists the open ports and checks them again on demand", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices/burns-node")

    assert eventually(fn -> has_element?(view, "#open-ports-table", "Proxmox") end)
    assert has_element?(view, "#open-ports-table", "SSH")

    render_click(element(view, "#refresh-ports"))
    assert eventually(fn -> has_element?(view, "#open-ports-table", "8006") end)
  end

  test "wake-on-LAN sends the magic packet and tells when the device answers", %{conn: conn} do
    Phoenix.PubSub.subscribe(Belgo.PubSub, Belgo.Fixtures.WakeOnLan.topic())
    {:ok, view, _html} = live(conn, ~p"/devices/burns-node")

    html = render_click(element(view, "#wake-0"))
    assert html =~ "Magic packet sent to Burns Node"

    assert_receive {:magic_packet, packet, ["255.255.255.255", "10.0.0.255"]}
    assert 102 == byte_size(packet)

    # The fixture pinger answers for Burns Node: the notice shows up on the page.
    assert eventually(fn -> render(view) =~ "Burns Node is awake" end)
  end

  test "the device list sorts by address and keeps the order in the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices")

    render_click(element(view, ~s(th button[phx-value-field="address"])))
    assert_patch(view, ~p"/devices?sort=address")

    render_click(element(view, ~s(th button[phx-value-field="address"])))
    assert_patch(view, ~p"/devices?direction=desc&sort=address")

    {:ok, sorted, _html} = live(conn, ~p"/devices?sort=address&direction=desc")

    ids =
      Regex.scan(~r/id="device-([a-z0-9-]+)"/, render(sorted), capture: :all_but_first)

    # Descending addresses: Smithers (10.0.0.11) comes before Burns Node (10.0.0.10).
    assert Enum.find_index(ids, &(&1 == ["smithers"])) <
             Enum.find_index(ids, &(&1 == ["burns-node"]))
  end

  test "a network gets logical ranges from its form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/networks/springfield/edit")

    # The "Add" button dispatches the form change event in the browser.
    view
    |> form("#network-form")
    |> render_change(%{"network" => %{"ranges_sort" => ["new"]}})

    view
    |> form("#network-form")
    |> render_change(%{"network" => %{"ranges_sort" => ["0", "new"]}})

    assert {:error, {:live_redirect, %{to: "/networks/springfield"}}} =
             view
             |> form("#network-form",
               network: %{
                 ranges: %{
                   "0" => %{
                     name: "Routing",
                     start: "10.0.0.1",
                     end: "10.0.0.5",
                     kinds: ["network"]
                   },
                   "1" => %{
                     name: "Media",
                     start: "10.0.0.8",
                     end: "10.0.0.12",
                     kinds: ["media", "gaming"]
                   }
                 }
               }
             )
             |> render_submit()

    assert {:ok,
            %{
              ranges: [
                %{name: "Routing", start: "10.0.0.1", end: "10.0.0.5", kinds: [:network]},
                %{name: "Media", kinds: [:media, :gaming]}
              ]
            }} =
             Belgo.Inventory.Snapshot.fetch(Belgo.Inventory.snapshot(), :networks, "springfield")

    {:ok, _index, html} = live(conn, ~p"/networks")
    assert html =~ "Routing"

    # The show page lists every address of each range, free ones included.
    {:ok, view, _html} = live(conn, ~p"/networks/springfield")
    refute has_element?(view, "#network-form")
    assert has_element?(view, ~s(a[href="/networks/springfield/edit"]))
    assert has_element?(view, "#range-0-rows tr[data-address]", "10.0.0.1")
    assert has_element?(view, ~s(#range-0-rows tr[data-address="10.0.0.2"]), "Plow King")
    assert has_element?(view, ~s(#range-0-rows tr[data-address="10.0.0.3"][data-free]))
    refute has_element?(view, ~s(#range-0-rows tr[data-address="10.0.0.2"] [data-kind-mismatch]))

    # Burns Node is a server in the Media range: flagged.
    assert has_element?(
             view,
             ~s(#range-1-rows tr[data-address="10.0.0.10"] [data-kind-mismatch]),
             ""
           )
  end

  test "choosing a kind with a range on a new device suggests an address", %{conn: conn} do
    {:ok, _network} =
      Belgo.Inventory.update(
        :networks,
        "springfield",
        %{
          "ranges" => [
            %{
              "name" => "Living room",
              "start" => "10.0.0.30",
              "end" => "10.0.0.40",
              "kinds" => ["media", "gaming"]
            }
          ]
        },
        user: :system
      )

    {:ok, view, _html} = live(conn, ~p"/devices/new")

    html =
      view
      |> form("#device-form", device: %{name: "Itchy & Scratchy", kind: "gaming"})
      |> render_change()

    assert has_element?(view, ~s(input[name="device[interfaces][0][ip]"][value="10.0.0.30"]))
    assert html =~ "First free address of Living room"
  end

  test "editing a device offers the next free address of its kind's range", %{conn: conn} do
    {:ok, _network} =
      Belgo.Inventory.update(
        :networks,
        "springfield",
        %{
          "ranges" => [
            %{"name" => "Media", "start" => "10.0.0.30", "end" => "10.0.0.40", "kind" => "media"}
          ]
        },
        user: :system
      )

    {:ok, view, _html} = live(conn, ~p"/devices/tv-living-room/edit")

    # The TV keeps 10.0.0.20 until the offered address is used.
    assert has_element?(view, ~s(input[name="device[interfaces][0][ip]"][value="10.0.0.20"]))
    assert has_element?(view, "#range-suggestion-0", "Next free address of Media")
    assert has_element?(view, "#range-suggestion-0 button", "10.0.0.30")

    # The button fills the field in the browser, which then sends it like typing.
    view
    |> form("#device-form", device: %{interfaces: %{"0" => %{ip: "10.0.0.30"}}})
    |> render_change()

    refute has_element?(view, "#range-suggestion-0")
  end

  defp eventually(check, attempts \\ 40) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(25) && eventually(check, attempts - 1)
    end
  end
end
