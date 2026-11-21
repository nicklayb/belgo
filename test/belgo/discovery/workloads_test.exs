defmodule Belgo.Discovery.WorkloadsTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.Correlation.Divergence
  alias Belgo.Discovery.Workload
  alias Belgo.Discovery.Workload.HostReference
  alias Belgo.Discovery.Workloads
  alias Belgo.Discovery.Workloads.LivePlacement
  alias Belgo.Discovery.Workloads.UnknownHost
  alias Belgo.Fixtures
  alias Belgo.Inventory.Snapshot

  # Burns Node and a second Proxmox node, Flanders Node.
  defp snapshot do
    flanders_node =
      Fixtures.device(
        id: "flanders-node",
        name: "Flanders Node",
        kind: :server,
        platforms: [:proxmox],
        interfaces: [Fixtures.interface(mac: "02:00:00:00:00:31", ip: "10.0.0.30")]
      )

    Snapshot.put(Fixtures.snapshot(), :devices, flanders_node)
  end

  defp workload(attributes) do
    struct!(
      %Workload{
        provider: :proxmox,
        source: :proxmox_vm,
        kind: :virtual_machine,
        name: "Smithers-VM",
        host: %HostReference{name: "burns"}
      },
      attributes
    )
  end

  describe "host resolution" do
    test "explicit device, then MAC, then IP, then names" do
      workloads =
        Workloads.correlate(snapshot(), [
          workload(
            name: "explicit",
            host: %HostReference{name: "cadvisor", device_id: "smithers"}
          ),
          workload(name: "by-mac", host: %HostReference{name: "x", macs: ["02:00:00:00:00:31"]}),
          workload(name: "by-ip", host: %HostReference{name: "x", ips: ["10.0.0.10"]}),
          workload(name: "by-label", host: %HostReference{name: "smithers.springfield.lan"}),
          workload(name: "by-dns-name", host: %HostReference{name: "assistant"}),
          workload(name: "nowhere", host: %HostReference{name: "moes-tavern"})
        ])

      names_by_host =
        Map.new(workloads.by_host, fn {host_id, hosted} ->
          {host_id, Enum.map(hosted, & &1.name)}
        end)

      assert names_by_host == %{
               "smithers" => ["by-dns-name", "by-label", "explicit"],
               "flanders-node" => ["by-mac"],
               "burns-node" => ["by-ip"]
             }

      assert [
               %UnknownHost{
                 name: "moes-tavern",
                 provider: :proxmox,
                 workloads: [%{name: "nowhere"}]
               }
             ] =
               workloads.unknown_hosts
    end

    test "on_host/3 filters by kind" do
      workloads =
        Workloads.correlate(snapshot(), [
          workload(kind: :pod, name: "krusty-0", host: %HostReference{name: "smithers"}),
          workload(kind: :container, name: "duff", host: %HostReference{name: "smithers"})
        ])

      assert [%Workload{name: "krusty-0", host_id: "smithers"}] =
               Workloads.on_host(workloads, "smithers", :pod)

      assert Workloads.on_host(workloads, "homer-pc", [:pod, :container]) == []
    end
  end

  describe "guest placement" do
    test "a guest on its inventory host matches, no divergence" do
      workloads =
        Workloads.correlate(snapshot(), [
          workload(
            macs: ["02:00:00:00:00:11"],
            host: %HostReference{name: "burns", ips: ["10.0.0.10"]}
          )
        ])

      assert %LivePlacement{matches?: true, host_id: "burns-node", device_id: "smithers"} =
               Workloads.placement(workloads, "smithers")

      assert workloads.divergences == []
    end

    test "a guest running on another node is a divergence with its live placement" do
      workloads =
        Workloads.correlate(snapshot(), [
          workload(
            macs: ["02:00:00:00:0a:11", "02:00:00:00:00:11"],
            status: "running",
            host: %HostReference{name: "flanders", ips: ["10.0.0.30"]}
          )
        ])

      assert %LivePlacement{
               matches?: false,
               host_id: "flanders-node",
               host_name: "Flanders Node",
               guest_name: "Smithers-VM",
               status: "running"
             } = Workloads.placement(workloads, "smithers")

      assert [
               %Divergence{
                 collection: :devices,
                 id: "smithers",
                 provider: :proxmox,
                 message: "Smithers-VM runs on Flanders Node, Belgo has Burns Node"
               }
             ] = workloads.divergences
    end

    test "a guest on an unknown node, or a device without host, diverges too" do
      workloads =
        Workloads.correlate(snapshot(), [
          workload(macs: ["02:00:00:00:00:11"], host: %HostReference{name: "spider-pig"}),
          workload(
            name: "TV",
            macs: ["02:00:00:00:00:20"],
            host: %HostReference{name: "burns", ips: ["10.0.0.10"]}
          )
        ])

      assert Enum.map(workloads.divergences, & &1.message) == [
               "Smithers-VM runs on spider-pig (unknown to Belgo), Belgo has Burns Node",
               "TV runs on Burns Node, Belgo has no host"
             ]
    end

    test "guests unknown to the inventory have no device" do
      workloads =
        Workloads.correlate(snapshot(), [workload(name: "Duffman", macs: ["02:00:00:00:0d:0f"])])

      assert workloads.placements == %{}

      assert [%Workload{name: "Duffman", device_id: nil}] =
               hd(workloads.unknown_hosts).workloads
    end

    test "host_params/2 moves the device keeping its fields" do
      device = Fixtures.device(id: "tv-living-room", name: "TV", location_id: "living-room")

      placement = %LivePlacement{
        device_id: "tv-living-room",
        provider: :proxmox,
        host_id: "burns-node",
        host_name: "Burns Node",
        guest_name: "TV",
        kind: :lxc
      }

      assert %{
               "placement" => "host",
               "host_id" => "burns-node",
               "virtualization" => "lxc",
               "name" => "TV"
             } = Workloads.host_params(device, placement)
    end
  end

  test "the correlation carries workloads and their divergences" do
    correlation =
      Correlation.build(snapshot(), [], [
        workload(
          macs: ["02:00:00:00:00:11"],
          host: %HostReference{name: "flanders", ips: ["10.0.0.30"]}
        )
      ])

    assert %Workloads{placements: %{"smithers" => %LivePlacement{}}} = correlation.workloads

    assert [%Divergence{message: "Smithers-VM runs on Flanders Node, Belgo has Burns Node"}] =
             Correlation.divergences_for(correlation, :devices, "smithers")
  end
end
