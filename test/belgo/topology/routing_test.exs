defmodule Belgo.Topology.RoutingTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Uplink
  alias Belgo.Fixtures
  alias Belgo.Inventory.Snapshot
  alias Belgo.Topology.Routing
  alias Belgo.Topology.Routing.Link
  alias Belgo.Topology.Routing.Node

  defp snapshot do
    Fixtures.snapshot()
    |> Snapshot.put(
      :devices,
      Fixtures.device(
        id: "attic-switch",
        name: "Attic Switch",
        kind: :network,
        network_role: :switch,
        interfaces: [
          Fixtures.interface(
            mac: nil,
            ip: nil,
            assignment: :dynamic,
            switch_id: "plow-king",
            switch_port: "8"
          )
        ]
      )
    )
    |> Snapshot.put(
      :devices,
      Fixtures.device(
        id: "homepod",
        name: "HomePod Mini",
        kind: :media,
        interfaces: [Fixtures.interface(mac: "02:00:00:00:00:77", ip: "10.0.0.77")]
      )
    )
  end

  test "live uplinks win over the inventory, which is the fallback" do
    uplinks = %{
      "homepod" => %Uplink{
        device_id: "homepod",
        provider: :omada,
        switch_id: "attic-switch",
        wireless?: true,
        ssid: "Springfield",
        locked_to_ap: true
      }
    }

    links = Routing.links(snapshot(), uplinks)

    assert %Link{source: :omada, switch_id: "attic-switch", wireless?: true} = links["homepod"]
    assert %Link{source: :inventory, switch_id: "plow-king", port: "1"} = links["burns-node"]
    refute Map.has_key?(links, "lisa-laptop")
  end

  test "the tree starts at the gateway and lists clients under their node" do
    uplinks = %{
      "homepod" => %Uplink{device_id: "homepod", provider: :omada, switch_id: "attic-switch"}
    }

    snapshot = snapshot()

    assert [%Node{device: %{id: "power-plant"}, children: [plow_king]}] =
             Routing.build(snapshot, Routing.links(snapshot, uplinks))

    assert %Node{
             device: %{id: "plow-king"},
             children: [attic],
             clients: [{%{id: "burns-node"}, _link}]
           } = plow_king

    assert %Node{device: %{id: "attic-switch"}, clients: [{%{id: "homepod"}, _homepod_link}]} =
             attic
  end

  test "the path goes from the device up to the gateway" do
    uplinks = %{
      "homepod" => %Uplink{device_id: "homepod", provider: :omada, switch_id: "attic-switch"}
    }

    snapshot = snapshot()

    assert ["HomePod Mini", "Attic Switch", "Plow King", "Power Plant"] ==
             snapshot
             |> Routing.path(Routing.links(snapshot, uplinks), "homepod")
             |> Enum.map(& &1.name)
  end

  test "a node unknown to Belgo ends the path by its provider name" do
    uplinks = %{
      "homepod" => %Uplink{device_id: "homepod", provider: :omada, switch_name: "AP Ground Floor"}
    }

    snapshot = snapshot()

    assert [%{name: "HomePod Mini"}, %{device: nil, name: "AP Ground Floor"}] =
             Routing.path(snapshot, Routing.links(snapshot, uplinks), "homepod")
  end

  test "cycles are cut" do
    snapshot =
      Snapshot.put(
        snapshot(),
        :devices,
        Fixtures.device(
          id: "power-plant",
          name: "Power Plant",
          kind: :network,
          network_role: :gateway,
          interfaces: [
            Fixtures.interface(
              mac: nil,
              ip: "10.0.0.1",
              assignment: :static,
              switch_id: "plow-king"
            )
          ]
        )
      )

    links = Routing.links(snapshot, %{})

    assert ["Plow King", "Power Plant"] ==
             snapshot
             |> Routing.path(links, "plow-king")
             |> Enum.map(& &1.name)

    assert [_root | _other_roots] = Routing.build(snapshot, links)
  end

  test "network devices without interface are linked by their uplink" do
    snapshot =
      Snapshot.put(
        snapshot(),
        :devices,
        Fixtures.device(
          id: "attic-switch",
          name: "Attic Switch",
          kind: :network,
          network_role: :switch,
          uplink_id: "plow-king",
          uplink_port: "8"
        )
      )

    links = Routing.links(snapshot, %{})

    assert %Link{source: :inventory, switch_id: "plow-king", switch_name: "Plow King", port: "8"} =
             links["attic-switch"]

    hops = Routing.path(snapshot, links, "attic-switch")
    assert ["Attic Switch", "Plow King", "Power Plant"] == Enum.map(hops, & &1.name)
  end
end
