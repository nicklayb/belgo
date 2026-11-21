defmodule BelgoWeb.HostingTest do
  use BelgoWeb.ConnCase

  alias Belgo.Accounts.User
  alias Belgo.Inventory
  alias Belgo.Inventory.Snapshot

  describe "with Prometheus" do
    setup do
      enable_providers(
        "version: 1\nproviders:\n  prometheus:\n    url: https://prometheus.springfield.lan\n"
      )

      :ok
    end

    test "pods are nested under their application, bare pods at the top", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hosting")

      assert has_element?(view, "#pods-smithers", "22 pods")

      assert has_element?(
               view,
               ~s(#pods-smithers-group-sector-7g-nuclear-plant[data-workload-group="nuclear-plant"]),
               "11"
             )

      assert has_element?(
               view,
               ~s(#pods-smithers-group-sector-7g-nuclear-plant [data-pod="nuclear-plant-5d8f-11"])
             )

      refute has_element?(view, ~s(#pods-smithers-group-sector-7g-nuclear-plant[open]))
      assert has_element?(view, ~s(#pods-smithers > ul > li > [data-pod="bart-prank-01"]))
    end

    test "nodes list their first entries, groups first, and expand on demand", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hosting")

      assert count_entries(view) == 10
      assert has_element?(view, ~s(#pods-smithers [data-workload-group="krusty-show"]))
      refute has_element?(view, ~s(#pods-smithers [data-pod="bart-prank-10"]))

      render_click(element(view, "#toggle-pods-smithers", "Show 2 more"))

      assert count_entries(view) == 12
      assert has_element?(view, ~s(#pods-smithers [data-pod="bart-prank-10"]))
      assert has_element?(view, "#toggle-pods-smithers", "Show fewer")
    end

    test "pods are filtered by application, its group open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hosting")

      refute has_element?(
               view,
               ~s(#app-filter-select option[value="springfield-elementary/bart-prank-01"])
             )

      view
      |> form("#app-filter", %{"app" => "entertainment/krusty-show"})
      |> render_change()

      assert_patch(view, ~p"/hosting?app=entertainment%2Fkrusty-show")

      assert has_element?(
               view,
               ~s(#pods-smithers-group-entertainment-krusty-show-filtered[open] [data-pod="krusty-0"])
             )

      refute has_element?(view, ~s(#pods-smithers [data-pod="nuclear-plant-5d8f-01"]))
      refute has_element?(view, ~s(#pods-smithers [data-pod="bart-prank-01"]))
    end

    test "Docker hosts nest containers under their Compose project, one host per row",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hosting")

      assert has_element?(
               view,
               ~s(#containers-smithers-group-duff [data-container="duff-brewery"]),
               "duff/beer"
             )

      assert has_element?(view, ~s(#platform-docker > [data-layout="rows"]))
      assert has_element?(view, ~s(#platform-kubernetes > [data-layout="rows"]))
      assert has_element?(view, "#unknown-hosts", "cadvisor")
    end
  end

  describe "with Proxmox" do
    setup do
      flanders_node = %{
        "id" => "flanders-node",
        "name" => "Flanders Node",
        "kind" => "server",
        "platforms" => ["proxmox"],
        "interfaces" => [%{"mac" => "02:00:00:00:00:31", "ip" => "10.0.0.30"}]
      }

      {:ok, _device} =
        Inventory.create(:devices, flanders_node, user: %User{username: "ned"})

      enable_providers(
        "version: 1\nproviders:\n  proxmox:\n    url: https://pve.springfield.lan:8006\n"
      )

      :ok
    end

    test "the device page shows where a guest runs and sets its host on click", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/devices/smithers")

      assert html =~ "Smithers-VM runs on Flanders Node, Belgo has Burns Node"
      assert has_element?(view, ~s(#live-placement[data-matches="false"]), "Flanders Node")

      render_click(element(view, "#live-placement-set-host"))

      assert {:ok, %{host_id: "flanders-node", virtualization: :virtual_machine}} =
               Snapshot.fetch(Inventory.snapshot(), :devices, "smithers")
    end

    test "Proxmox nodes show guests running elsewhere and unknown ones", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/hosting")

      assert has_element?(view, "#placement-burns-node-smithers", "Flanders Node")

      assert has_element?(
               view,
               ~s(#live-guests-burns-node [data-live-guest="Duffman"]),
               "Not in Belgo"
             )

      assert has_element?(view, ~s(#live-guests-flanders-node [data-live-guest="Smithers-VM"]))

      render_click(element(view, "#set-host-flanders-node-smithers"))

      assert {:ok, %{host_id: "flanders-node"}} =
               Snapshot.fetch(Inventory.snapshot(), :devices, "smithers")
    end
  end

  defp count_entries(view),
    do: length(Regex.scan(~r/<li class="text-sm"/, render(element(view, "#pods-smithers"))))
end
