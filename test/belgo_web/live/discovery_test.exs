defmodule BelgoWeb.DiscoveryTest do
  use BelgoWeb.ConnCase

  alias Belgo.Inventory
  alias Belgo.Inventory.Snapshot

  test "explains how to enable providers", %{conn: conn} do
    Belgo.Discovery.refresh()
    {:ok, _view, html} = live(conn, ~p"/discovery")

    assert html =~ "No provider configured"
  end

  describe "with OPNsense" do
    setup do
      enable_opnsense()
      :ok
    end

    test "lists unknown devices, new networks and divergences", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/discovery")

      assert html =~ "moe-pc"
      assert html =~ "10.0.5.0/24"
      assert html =~ "reservation of 02:00:00:00:00:11 uses 10.0.0.99, Belgo has 10.0.0.11"
    end

    test "cards are collapsible, unknown devices collapsed by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/discovery")

      assert has_element?(
               view,
               ~s(details[phx-hook="Collapsible"][data-collapse-key="discovery-new-networks"][open])
             )

      assert has_element?(view, ~s(details[data-collapse-key="discovery-unknown-devices"]))
      refute has_element?(view, ~s(details[data-collapse-key="discovery-unknown-devices"][open]))
      # Collapsed content is still rendered, the browser only hides it.
      assert has_element?(view, "#unknown-devices", "moe-pc")
    end

    test "unknown devices are pinged and show whether they answer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/discovery")

      assert Enum.find_value(1..20, fn _attempt ->
               has_element?(view, ~s(#unknown-devices [data-reachability][data-state="down"])) ||
                 (Process.sleep(50) && nil)
             end)
    end

    test "claiming a device prefills the form and saves it", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/devices/new?discovered=mac-02-00-00-00-05-01")

      assert html =~ "Reported by providers"
      assert html =~ "Moe&#39;s PC"

      assert {:error, {:live_redirect, %{to: "/devices/moe-pc"}}} =
               view
               |> form("#device-form")
               |> render_submit()

      assert {:ok, device} = Snapshot.fetch(Inventory.snapshot(), :devices, "moe-pc")

      assert [
               %{
                 mac: "02:00:00:00:05:01",
                 ip: "10.0.0.50",
                 network_id: "springfield",
                 dns_names: ["moe-pc", "tavern"]
               }
             ] = device.interfaces
    end

    test "claims a DNS name on the interface holding its address", %{conn: conn} do
      release_assistant_name()
      {:ok, view, _html} = live(conn, ~p"/discovery")

      assert has_element?(view, "#dns-names", "assistant.springfield.lan")
      assert has_element?(view, "#dns-names", "Smithers")

      {:ok, claim, _html} =
        live(conn, ~p"/discovery/dns-names/dns-assistant-springfield-lan-10-0-0-11")

      assert has_element?(
               claim,
               ~s(#claim-dns-name_target option[value="devices:smithers"][selected])
             )

      assert has_element?(claim, "#claim-summary", "assistant")
      refute has_element?(claim, "#claim-address-warning")

      submitted = render_submit(form(claim, "#claim-dns-name"))
      assert {:error, {:live_redirect, %{to: "/discovery"}}} = submitted

      # Back on Discovery, the notice links to the device.
      {:ok, discovery, _html} = follow_redirect(submitted, conn)

      assert has_element?(
               discovery,
               ~s(#flash-info a[href="/devices/smithers"]),
               "Smithers"
             )

      assert has_element?(discovery, "#flash-info", "assistant.springfield.lan added to")

      # No whitespace between the segments (the notice once became a huge block).
      assert render(element(discovery, "#flash-info p")) =~
               ~r{assistant.springfield.lan added to <a [^>]*>Smithers</a>\.}

      refute has_element?(discovery, "#dns-names", "assistant.springfield.lan")

      assert {:ok, device} = Snapshot.fetch(Inventory.snapshot(), :devices, "smithers")
      assert ["smithers", "assistant"] == hd(device.interfaces).dns_names
    end

    test "a DNS name can be claimed by another device", %{conn: conn} do
      release_assistant_name()

      {:ok, claim, _html} =
        live(conn, ~p"/discovery/dns-names/dns-assistant-springfield-lan-10-0-0-11")

      claim
      |> form("#claim-dns-name", claim: %{target: "devices:burns-node"})
      |> render_change()

      assert has_element?(claim, "#claim-address-warning", "10.0.0.10")

      assert {:error, {:live_redirect, %{to: "/discovery"}}} =
               claim
               |> form("#claim-dns-name")
               |> render_submit()

      assert {:ok, device} = Snapshot.fetch(Inventory.snapshot(), :devices, "burns-node")
      assert "assistant" in hd(device.interfaces).dns_names
    end

    test "a reservation on an address OPNsense reserved for another MAC is refused", %{
      conn: conn
    } do
      # Moe's PC, claimed with the address OPNsense reserved for Nelson's phone.
      {:ok, view, _html} = live(conn, ~p"/devices/new?discovered=mac-02-00-00-00-05-01")

      html =
        view
        |> form("#device-form", device: %{interfaces: %{"0" => %{ip: "10.0.0.66"}}})
        |> render_submit()

      assert html =~
               "10.0.0.66 is already reserved in OPNsense for 02:00:00:00:06:66 (nelson-iphone)"

      assert {:error, :not_found} = Snapshot.fetch(Inventory.snapshot(), :devices, "moe-pc")
    end

    test "choosing a kind with a logical range suggests its first free address", %{conn: conn} do
      {:ok, _network} =
        Inventory.update(
          :networks,
          "springfield",
          %{
            "ranges" => [
              %{"name" => "IoT", "start" => "10.0.0.66", "end" => "10.0.0.80", "kind" => "iot"}
            ]
          },
          user: :system
        )

      {:ok, view, _html} = live(conn, ~p"/devices/new?discovered=mac-02-00-00-00-05-01")

      html =
        view
        |> form("#device-form", device: %{kind: "iot"})
        |> render_change()

      # 10.0.0.66 is reserved in OPNsense for Nelson's phone: 10.0.0.67 is the first free one.
      assert has_element?(view, ~s(input[name="device[interfaces][0][ip]"][value="10.0.0.67"]))
      assert html =~ "First free address of IoT (10.0.0.66 – 10.0.0.80)."

      assert {:error, {:live_redirect, %{to: "/devices/moe-pc"}}} =
               view
               |> form("#device-form")
               |> render_submit()

      assert {:ok, %{interfaces: [%{ip: "10.0.0.67"}]}} =
               Snapshot.fetch(Inventory.snapshot(), :devices, "moe-pc")
    end

    test "devices outside the DHCP range are listed apart", %{conn: conn} do
      {:ok, _network} =
        Inventory.update(
          :networks,
          "springfield",
          %{"dhcp_start" => "10.0.0.60", "dhcp_end" => "10.0.0.99"},
          user: :system
        )

      {:ok, _view, html} = live(conn, ~p"/discovery")

      assert html =~ "Out of DHCP"
      assert html =~ ~s(id="out-of-dhcp-devices")
    end

    test "the out of DHCP table sorts by device or address", %{conn: conn} do
      {:ok, _network} =
        Inventory.update(
          :networks,
          "springfield",
          %{"dhcp_start" => "10.0.0.200", "dhcp_end" => "10.0.0.250"},
          user: :system
        )

      {:ok, view, html} = live(conn, ~p"/discovery")
      assert html =~ ~s(aria-sort="ascending")

      by_address = out_of_dhcp_names(html)

      by_device =
        out_of_dhcp_names(render_click(view, "sort_out_of_dhcp", %{"field" => "device"}))

      by_device_descending =
        out_of_dhcp_names(render_click(view, "sort_out_of_dhcp", %{"field" => "device"}))

      assert length(by_address) > 1
      assert by_device == Enum.sort(by_device)
      assert Enum.reverse(by_device) == by_device_descending
      assert_patch(view, "/discovery?direction=desc&sort=device")
    end

    test "the out of DHCP filter and order are restored from the URL", %{conn: conn} do
      {:ok, _network} =
        Inventory.update(
          :networks,
          "springfield",
          %{"dhcp_start" => "10.0.0.200", "dhcp_end" => "10.0.0.250"},
          user: :system
        )

      {:ok, view, html} = live(conn, ~p"/discovery?sort=device&direction=desc&provider=opnsense")
      names = out_of_dhcp_names(html)

      assert length(names) > 1
      assert Enum.sort(names, :desc) == names
      assert html =~ ~s(aria-sort="descending")
      assert has_element?(view, ~s(#out-of-dhcp-filter option[value="opnsense"][selected]))

      {:ok, _view, html} = live(conn, ~p"/discovery?query=krusty")
      assert html =~ "No device matches"
      assert html =~ ~s(value="krusty")
    end

    test "a discovered device can be attached to an existing device", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/devices/new?discovered=mac-02-00-00-00-05-01")

      assert html =~ "Attach to an existing device"

      assert {:error, {:live_redirect, %{to: "/devices/burns-node"}}} =
               view
               |> form("#attach-form", attach: %{device_id: "burns-node"})
               |> render_submit()

      assert {:ok, burns} = Snapshot.fetch(Inventory.snapshot(), :devices, "burns-node")
      assert ["02:00:00:00:00:10", "02:00:00:00:05:01"] == Enum.map(burns.interfaces, & &1.mac)
    end

    test "out of DHCP devices can be filtered", %{conn: conn} do
      {:ok, _network} =
        Inventory.update(
          :networks,
          "springfield",
          %{"dhcp_start" => "10.0.0.60", "dhcp_end" => "10.0.0.99"},
          user: :system
        )

      %Belgo.Discovery.State{} = Belgo.Discovery.state()
      {:ok, view, html} = live(conn, ~p"/discovery")
      assert html =~ "moe-pc"

      html =
        view
        |> form("#out-of-dhcp-filter", %{query: "10.0.0.50"})
        |> render_change()

      assert html =~ ~s(id="out-of-dhcp-devices")
      assert_patch(view, "/discovery?query=10.0.0.50")

      html =
        view
        |> form("#out-of-dhcp-filter", %{query: "krusty"})
        |> render_change()

      assert html =~ "No device matches"

      html =
        view
        |> form("#out-of-dhcp-filter", %{query: "", provider: "opnsense"})
        |> render_change()

      assert html =~ ~s(id="out-of-dhcp-devices")
    end

    test "claiming a network prefills the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/networks/new?discovered=10-0-5-0-24")

      assert {:error, {:live_redirect, %{to: "/networks/" <> _id}}} =
               view
               |> form("#network-form")
               |> render_submit()

      assert {:ok,
              %{
                cidr: "10.0.5.0/24",
                gateway: "10.0.5.1",
                dhcp_start: "10.0.5.100",
                dhcp_end: "10.0.5.199"
              }} =
               Snapshot.fetch(Inventory.snapshot(), :networks, "shelbyville")
    end

    test "ignoring a device adds it to the denylist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/discovery")

      render_click(view, "ignore", %{"id" => "mac-02-00-00-00-06-66"})

      assert {:ok, %{name: "nelson-iphone"}} =
               Snapshot.fetch(Inventory.snapshot(), :denylist, "02:00:00:00:06:66")
    end

    test "the overview lists divergences and counts what needs fixing", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Divergences with providers"
      assert html =~ "reservation of 02:00:00:00:00:11 uses 10.0.0.99, Belgo has 10.0.0.11"
      assert html =~ ~s(aria-label="Overview:)
    end

    test "device pages show their divergences", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/devices/smithers")

      assert html =~ "Divergences with providers"
    end
  end

  describe "navigation badge" do
    test "counts only the devices out of the DHCP pool", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/devices")
      refute html =~ ~s(aria-label="Discovery:)

      enable_opnsense()
      refute render(view) =~ ~s(aria-label="Discovery:)

      {:ok, _network} =
        Inventory.update(
          :networks,
          "springfield",
          %{"dhcp_start" => "10.0.0.60", "dhcp_end" => "10.0.0.99"},
          user: :system
        )

      %Belgo.Discovery.State{} = Belgo.Discovery.state()
      assert render(view) =~ ~s(aria-label="Discovery: 1")
    end
  end

  describe "push" do
    setup do
      enable_opnsense()
      :ok
    end

    test "saving a device pushes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/devices/smithers/edit")

      view
      |> form("#device-form")
      |> render_submit()

      assert_receive {:discovery_changed, %{providers: [%{last_push: %{device_id: "smithers"}}]}},
                     1_000
    end

    test "devices can be pushed manually", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/devices/burns-node")

      assert render_click(view, "push", %{}) =~ "Push started"

      assert_receive {:discovery_changed,
                      %{providers: [%{last_push: %{device_id: "burns-node"}}]}},
                     1_000
    end
  end

  test "a failed provider can be pulled again on its own", %{conn: conn} do
    enable_providers(
      "version: 1\nproviders:\n  home_assistant:\n    url: https://broken.example\n"
    )

    {:ok, view, html} = live(conn, ~p"/discovery")
    assert html =~ "auth_invalid"

    assert has_element?(
             view,
             ~s(button[phx-click="refresh-provider"][phx-value-provider="home_assistant"])
           )

    render_click(view, "refresh-provider", %{"provider" => "home_assistant"})

    assert_receive {:discovery_changed, %{providers: [%{running?: true}]}}, 1_000

    assert_receive {:discovery_changed,
                    %{providers: [%{running?: false, error: {:auth_invalid, _message}}]}},
                   1_000
  end

  test "a working provider has no refresh button of its own", %{conn: conn} do
    enable_home_assistant()

    {:ok, view, _html} = live(conn, ~p"/discovery")
    refute has_element?(view, ~s(button[phx-click="refresh-provider"]))
  end

  describe "with Home Assistant" do
    setup do
      enable_home_assistant()
      :ok
    end

    test "lists the floors and areas missing from the inventory", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/discovery")

      assert html =~ ~s(id="new-locations")
      assert html =~ "Moe&#39;s Corner"
    end

    test "claiming a floor, then an area inside it", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/locations/new?discovered=floor-ground-floor")
      assert html =~ "Claim a discovered location"

      assert {:error, {:live_redirect, %{to: "/locations"}}} =
               view
               |> form("#location-form")
               |> render_submit()

      assert {:ok,
              %{
                kind: :floor,
                parent_id: "evergreen-terrace",
                home_assistant_id: "floor/ground_floor"
              }} =
               Snapshot.fetch(Inventory.snapshot(), :locations, "ground-floor")

      {:ok, view, _html} = live(conn, ~p"/locations/new?discovered=area-kitchen")

      assert {:error, {:live_redirect, %{to: "/locations"}}} =
               view
               |> form("#location-form")
               |> render_submit()

      assert {:ok, %{kind: :room, parent_id: "ground-floor", home_assistant_id: "area/kitchen"}} =
               Snapshot.fetch(Inventory.snapshot(), :locations, "kitchen")
    end
  end

  defp out_of_dhcp_names(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#out-of-dhcp-devices tr td:first-child p:first-child")
    |> Enum.map(&String.downcase(LazyHTML.text(&1)))
  end

  # Smithers owns assistant.springfield.lan in the fixtures, which OPNsense reports.
  defp release_assistant_name do
    {:ok, smithers} = Snapshot.fetch(Inventory.snapshot(), :devices, "smithers")
    attributes = Belgo.Inventory.Codec.encode(smithers)

    interfaces =
      Enum.map(attributes["interfaces"], &Map.put(&1, "dns_names", ["smithers"]))

    {:ok, _device} =
      Inventory.update(:devices, "smithers", Map.put(attributes, "interfaces", interfaces),
        user: :system
      )

    # The discovery server recorrelates on the inventory change, queued before this call.
    Belgo.Discovery.state()
  end
end
