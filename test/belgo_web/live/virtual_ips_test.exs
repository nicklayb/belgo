defmodule BelgoWeb.VirtualIpsTest do
  use BelgoWeb.ConnCase

  alias Belgo.Inventory
  alias Belgo.Inventory.Snapshot

  @kwik_e_mart %{
    "name" => "Kwik-E-Mart",
    "ip" => "10.0.0.110",
    "kind" => "metallb",
    "owner_id" => "burns-node",
    "dns_names" => "squishee, apu.kwik-e-mart.lan"
  }

  test "creates a virtual IP from the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/virtual-ips/new")

    assert {:error, {:live_redirect, %{to: "/virtual-ips"}}} =
             view
             |> form("#virtual-ip-form", virtual_ip: @kwik_e_mart)
             |> render_submit()

    assert {:ok, virtual_ip} = Snapshot.fetch(Inventory.snapshot(), :virtual_ips, "kwik-e-mart")

    assert %{ip: "10.0.0.110", kind: :metallb, dns_names: ["squishee", "apu.kwik-e-mart.lan"]} =
             virtual_ip

    {:ok, _index, html} = live(conn, ~p"/virtual-ips")
    assert html =~ "Kwik-E-Mart"
    assert html =~ "10.0.0.110"
  end

  test "the form shows inventory errors, such as an address used by a device", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/virtual-ips/new")

    html =
      view
      |> form("#virtual-ip-form", virtual_ip: %{@kwik_e_mart | "ip" => "10.0.0.10"})
      |> render_submit()

    assert html =~ "IP address 10.0.0.10 is also used by Burns Node"
  end

  test "the page shows its DNS names and owner; the owner lists it", %{conn: conn} do
    {:ok, _virtual_ip} = Inventory.create(:virtual_ips, @kwik_e_mart, user: :system)

    {:ok, view, _html} = live(conn, ~p"/virtual-ips/kwik-e-mart")
    assert has_element?(view, "#virtual-ip-dns-names", "squishee.springfield.lan")
    assert has_element?(view, "#virtual-ip-dns-names", "apu.kwik-e-mart.lan")
    assert has_element?(view, ~s(a[href="/devices/burns-node"]), "Burns Node")
    assert has_element?(view, "#open-ports")

    {:ok, device, _html} = live(conn, ~p"/devices/burns-node")
    assert has_element?(device, "#owned-virtual-ips", "Kwik-E-Mart")

    # Deleting the owner is refused while the virtual IP points to it.
    assert render_click(element(device, "button", "Delete")) =~ "Kwik-E-Mart"
    assert {:ok, _device} = Snapshot.fetch(Inventory.snapshot(), :devices, "burns-node")
  end

  test "the search finds a virtual IP by DNS name", %{conn: conn} do
    {:ok, _virtual_ip} = Inventory.create(:virtual_ips, @kwik_e_mart, user: :system)
    {:ok, view, _html} = live(conn, ~p"/")

    html =
      view
      |> form("#global-search form", search: %{query: "squishee"})
      |> render_change()

    assert html =~ ~s(href="/virtual-ips/kwik-e-mart")
    assert html =~ "Virtual IP"
  end

  describe "with OPNsense" do
    setup do
      enable_opnsense()
      :ok
    end

    test "an unknown address can be claimed as a virtual IP", %{conn: conn} do
      {:ok, discovery, _html} = live(conn, ~p"/discovery")

      assert has_element?(
               discovery,
               ~s(#unknown-devices a[href="/virtual-ips/new?discovered=mac-02-00-00-00-05-01"])
             )

      {:ok, view, _html} = live(conn, ~p"/virtual-ips/new?discovered=mac-02-00-00-00-05-01")

      assert has_element?(
               view,
               ~s(#virtual-ip-form input[name="virtual_ip[ip]"][value="10.0.0.50"])
             )

      assert has_element?(
               view,
               ~s(#virtual-ip-form input[name="virtual_ip[dns_names]"][value="moe-pc, tavern"])
             )
    end

    test "a discovered DNS name can be claimed by a virtual IP", %{conn: conn} do
      {:ok, _virtual_ip} = Inventory.create(:virtual_ips, @kwik_e_mart, user: :system)
      release_assistant_name()

      {:ok, claim, _html} =
        live(conn, ~p"/discovery/dns-names/dns-assistant-springfield-lan-10-0-0-11")

      claim
      |> form("#claim-dns-name", claim: %{target: "virtual_ips:kwik-e-mart"})
      |> render_change()

      assert has_element?(claim, "#claim-address-warning", "10.0.0.110")

      submitted = render_submit(form(claim, "#claim-dns-name"))
      assert {:error, {:live_redirect, %{to: "/discovery"}}} = submitted
      {:ok, discovery, _html} = follow_redirect(submitted, conn)
      assert has_element?(discovery, ~s(#flash-info a[href="/virtual-ips/kwik-e-mart"]))

      assert {:ok, virtual_ip} = Snapshot.fetch(Inventory.snapshot(), :virtual_ips, "kwik-e-mart")
      assert "assistant" in virtual_ip.dns_names
    end
  end

  # Smithers owns assistant.springfield.lan in the fixtures, which OPNsense reports.
  defp release_assistant_name do
    {:ok, smithers} = Snapshot.fetch(Inventory.snapshot(), :devices, "smithers")
    attributes = Belgo.Inventory.Codec.encode(smithers)
    interfaces = Enum.map(attributes["interfaces"], &Map.put(&1, "dns_names", ["smithers"]))

    {:ok, _device} =
      Inventory.update(:devices, "smithers", Map.put(attributes, "interfaces", interfaces),
        user: :system
      )

    Belgo.Discovery.state()
  end
end
