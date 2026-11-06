defmodule Belgo.TopologyTest do
  use ExUnit.Case, async: true

  import Belgo.Fixtures

  alias Belgo.Inventory.Snapshot
  alias Belgo.Topology.DeviceNode
  alias Belgo.Topology.Hosting
  alias Belgo.Topology.Physical

  test "the physical map nests locations and puts guests under their host" do
    map = Physical.build(snapshot())

    assert [%{location: %{id: "evergreen-terrace"}, locations: [basement, living_room]}] =
             map.roots

    assert "basement" == basement.location.id
    assert "living-room" == living_room.location.id

    assert [
             %DeviceNode{device: %{id: "burns-node"}, guests: [smithers]},
             %{device: %{id: "plow-king"}},
             %{device: %{id: "power-plant"}}
           ] =
             basement.devices

    assert [%DeviceNode{device: %{id: "itchy"}}] = smithers.guests
    assert ["lisa-laptop"] == DeviceNode.device_ids(map.portable)
    assert ["bart-console"] == DeviceNode.device_ids(map.unplaced)
  end

  test "devices in a cycle of hosts are still shown as unplaced" do
    snapshot =
      snapshot()
      |> Snapshot.put(
        :devices,
        device(id: "itchy", name: "Itchy", host_id: "scratchy", virtualization: :container)
      )
      |> Snapshot.put(
        :devices,
        device(id: "scratchy", name: "Scratchy", host_id: "itchy", virtualization: :container)
      )

    unplaced_ids =
      snapshot
      |> Physical.build()
      |> Map.fetch!(:unplaced)
      |> DeviceNode.device_ids()

    assert "itchy" in unplaced_ids
    assert "scratchy" in unplaced_ids
  end

  test "device_path/2 resolves the location through the hosts" do
    snapshot = snapshot()
    {:ok, itchy} = Snapshot.fetch(snapshot, :devices, "itchy")

    %{locations: locations, hosts: hosts} = Physical.device_path(snapshot, itchy)

    assert ["evergreen-terrace", "basement"] == Enum.map(locations, & &1.id)
    assert ["burns-node", "smithers"] == Enum.map(hosts, & &1.id)
  end

  test "devices_within/2 lists the devices of sub-locations and the guests of their hosts" do
    placements = Physical.devices_within(snapshot(), "evergreen-terrace")

    assert ["burns-node", "itchy", "plow-king", "power-plant", "smithers", "tv-living-room"] ==
             Enum.map(placements, & &1.device.id)

    assert %Physical.DevicePlacement{
             locations: [%{id: "basement"}],
             hosts: [%{id: "burns-node"}, %{id: "smithers"}]
           } =
             Enum.find(placements, &(&1.device.id == "itchy"))

    assert [%Physical.DevicePlacement{device: %{id: "tv-living-room"}, locations: []}] =
             Physical.devices_within(snapshot(), "living-room")
  end

  test "children/2 lists the locations directly inside, by name" do
    assert ["basement", "living-room"] ==
             snapshot()
             |> Physical.children("evergreen-terrace")
             |> Enum.map(& &1.id)

    assert [] == Physical.children(snapshot(), "basement")
  end

  test "location options are labelled with their path" do
    assert {"742 Evergreen Terrace / Basement", "basement"} in Physical.location_options(
             snapshot()
           )
  end

  test "the hosting tree starts from outermost hosts" do
    assert [
             %DeviceNode{
               device: %{id: "burns-node"},
               guests: [%{device: %{id: "smithers"}, guests: [_itchy]}]
             }
           ] =
             Hosting.build(snapshot())
  end

  describe "Hosting.groups/1" do
    test "groups hosts by platform with their direct guests of that platform" do
      assert [
               %Hosting.Group{
                 platform: :proxmox,
                 hosts: [
                   %Hosting.Host{
                     device: %{id: "burns-node"},
                     hosts: [],
                     guests: [%{id: "smithers"}]
                   }
                 ]
               },
               %Hosting.Group{
                 platform: :docker,
                 hosts: [
                   %Hosting.Host{
                     device: %{id: "smithers"},
                     hosts: [%{id: "burns-node"}],
                     guests: [%{id: "itchy"}]
                   }
                 ]
               }
             ] = Hosting.groups(snapshot())
    end

    test "a host of several platforms is in each, guests no platform runs are apart" do
      snapshot =
        snapshot()
        |> Snapshot.put(
          :devices,
          device(id: "krusty", name: "Krusty", platforms: [:docker, :kubernetes])
        )
        |> Snapshot.put(
          :devices,
          device(id: "clown", name: "Clown", host_id: "krusty", virtualization: :container)
        )
        |> Snapshot.put(
          :devices,
          device(
            id: "sideshow",
            name: "Sideshow",
            host_id: "krusty",
            virtualization: :virtual_machine
          )
        )
        |> Snapshot.put(
          :devices,
          device(id: "bob", name: "Bob", host_id: "tv-living-room", virtualization: :lxc)
        )

      groups = Map.new(Hosting.groups(snapshot), &{&1.platform, &1.hosts})

      assert MapSet.new([:docker, :kubernetes, :proxmox, nil]) == MapSet.new(Map.keys(groups))

      assert %{guests: [%{id: "clown"}]} = Enum.find(groups.docker, &(&1.device.id == "krusty"))
      assert [%{device: %{id: "krusty"}, guests: [%{id: "clown"}]}] = groups.kubernetes

      assert ["krusty", "tv-living-room"] == Enum.map(groups[nil], & &1.device.id)
      assert %{guests: [%{id: "sideshow"}]} = Enum.find(groups[nil], &(&1.device.id == "krusty"))
    end
  end
end
