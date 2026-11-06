defmodule Belgo.Inventory.AuditTest do
  use ExUnit.Case, async: true

  import Belgo.Fixtures

  alias Belgo.Inventory.Audit
  alias Belgo.Inventory.Issue
  alias Belgo.Inventory.Snapshot

  test "a consistent inventory has no issue" do
    assert [] == Audit.issues(snapshot())
  end

  test "reports duplicated addresses on every device involved" do
    snapshot =
      Snapshot.put(
        snapshot(),
        :devices,
        device(
          id: "flanders-pc",
          name: "Flanders PC",
          interfaces: [interface(mac: "02:00:00:00:00:99", ip: "10.0.0.10")]
        )
      )

    messages =
      snapshot
      |> Audit.issues()
      |> Enum.map(&{&1.id, &1.message})

    assert {"flanders-pc", "IP address 10.0.0.10 is also used by Burns Node"} in messages
    assert {"burns-node", "IP address 10.0.0.10 is also used by Flanders PC"} in messages
  end

  test "reports dangling references, cycles and out of range addresses" do
    snapshot =
      snapshot()
      |> Snapshot.put(
        :locations,
        location(id: "basement", name: "Basement", parent_id: "basement-annex")
      )
      |> Snapshot.put(
        :locations,
        location(id: "basement-annex", name: "Annex", parent_id: "basement")
      )
      |> Snapshot.put(
        :devices,
        device(
          id: "moe",
          name: "Moe",
          location_id: "tavern",
          interfaces: [interface(mac: "02:00:00:00:00:77", ip: "10.9.9.9")]
        )
      )

    issues = Audit.issues(snapshot)

    assert %Issue{severity: :error} = find(issues, "basement", "creates a cycle of locations")
    assert find(issues, "moe", "unknown location tavern")
    assert find(issues, "moe", "interface eth0: 10.9.9.9 is outside of Springfield (10.0.0.0/24)")
  end

  test "warns when the host declares no platform" do
    snapshot =
      Snapshot.put(
        snapshot(),
        :devices,
        device(id: "burns-node", name: "Burns Node", location_id: "basement")
      )

    assert %Issue{severity: :warning} =
             find(
               Audit.issues(snapshot),
               "smithers",
               "host Burns Node does not declare any platform"
             )
  end

  defp find(issues, id, message), do: Enum.find(issues, &(&1.id == id and &1.message == message))

  test "reports DNS names already used by another device" do
    snapshot =
      Snapshot.put(
        snapshot(),
        :devices,
        device(interfaces: [interface(dns_names: ["assistant"])])
      )

    assert find(
             Audit.issues(snapshot),
             "homer-pc",
             "DNS name assistant.springfield.lan is also used by Smithers"
           )
  end

  test "uplinks must exist and should be network devices" do
    snapshot =
      snapshot()
      |> Snapshot.put(
        :devices,
        device(
          id: "attic-switch",
          name: "Attic Switch",
          network_role: :switch,
          uplink_id: "nowhere"
        )
      )
      |> Snapshot.put(
        :devices,
        device(
          id: "garage-switch",
          name: "Garage Switch",
          network_role: :switch,
          uplink_id: "burns-node"
        )
      )

    issues = Audit.issues(snapshot)

    assert find(issues, "attic-switch", "unknown uplink device nowhere")

    assert %Issue{severity: :warning} =
             find(
               issues,
               "garage-switch",
               "plugged into Burns Node, which is not a network device"
             )
  end

  test "a switch used as uplink cannot be deleted" do
    snapshot =
      Snapshot.put(
        snapshot(),
        :devices,
        device(
          id: "attic-switch",
          name: "Attic Switch",
          network_role: :switch,
          uplink_id: "plow-king"
        )
      )

    assert {:devices, "attic-switch", "Attic Switch"} in Belgo.Inventory.References.list(
             snapshot,
             :devices,
             "plow-king"
           )
  end
end
