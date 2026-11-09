defmodule Belgo.Providers.OpnsensePushTest do
  use ExUnit.Case, async: true

  alias Belgo.Fixtures
  alias Belgo.Fixtures.OpnsenseClient
  alias Belgo.Inventory.Snapshot
  alias Belgo.Providers.Opnsense
  alias Belgo.Providers.Opnsense.Push
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.PushReport

  defp rows do
    %{
      subnets: OpnsenseClient.subnets(),
      reservations: OpnsenseClient.reservations(),
      host_overrides: OpnsenseClient.host_overrides()
    }
  end

  defp config(attributes) do
    struct!(
      %Opnsense.Config{
        url: "https://opnsense",
        api_key: "homer",
        api_secret: "donuts",
        client: OpnsenseClient
      },
      attributes
    )
  end

  defp summaries(%{operations: operations}), do: Enum.map(operations, & &1.summary)

  defp plan(desired_state, rows) do
    kea = Push.plan_kea(desired_state, rows)
    unbound = Push.plan_unbound(desired_state, rows)
    %{operations: kea.operations ++ unbound.operations, skipped: kea.skipped ++ unbound.skipped}
  end

  defp desired_state_for(device_id) do
    DesiredState.for_device(DesiredState.build(Fixtures.snapshot()), device_id)
  end

  test "creates missing entries, updates differing ones and never deletes" do
    plan = plan(DesiredState.build(Fixtures.snapshot()), rows())

    assert [
             "create reservation 02:00:00:00:00:02 → 10.0.0.2 (plow-king, Plow King (eth0))",
             "update reservation 02:00:00:00:00:10: description none → Burns Node (eth0)",
             "update reservation 02:00:00:00:00:11: ip 10.0.0.99 → 10.0.0.11; description none → Smithers (eth0)",
             "create reservation 02:00:00:00:00:20 → 10.0.0.20 (tv-living-room, TV Living Room)",
             "update host override smithers.springfield.lan: 10.0.0.10 → 10.0.0.11"
           ] == summaries(plan)

    assert [] == plan.skipped
    refute Enum.any?(plan.operations, &(&1.summary =~ ~r/moe|nelson|tavern|mail/))
  end

  test "builds the OPNsense payloads, updates only send managed fields" do
    %{operations: operations} = plan(DesiredState.build(Fixtures.snapshot()), rows())
    [create_reservation, _burns_update, update_reservation | _rest] = operations

    assert %Push.Operation{
             path: "/api/kea/dhcpv4/add_reservation",
             body: %{
               "reservation" => %{
                 "subnet" => "subnet-springfield",
                 "hw_address" => "02:00:00:00:00:02",
                 "ip_address" => "10.0.0.2",
                 "hostname" => "plow-king",
                 "description" => "Plow King (eth0)"
               }
             }
           } = create_reservation

    assert %Push.Operation{
             path: "/api/kea/dhcpv4/set_reservation/smithers",
             body: %{
               "reservation" => %{
                 "subnet" => "subnet-springfield",
                 "ip_address" => "10.0.0.11",
                 "hostname" => "smithers",
                 "description" => "Smithers (eth0)"
               }
             }
           } = update_reservation

    assert %Push.Operation{
             path: "/api/unbound/settings/set_host_override/smithers-wrong",
             body: %{"host" => %{"rr" => "A", "server" => "10.0.0.11"}}
           } = Enum.find(operations, &(&1.action == :update and &1.service == :unbound))
  end

  test "skips what cannot be written: no Kea subnet, no domain, existing Unbound alias" do
    snapshot =
      Fixtures.snapshot()
      |> Snapshot.put(
        :networks,
        Fixtures.network(
          id: "shelbyville",
          name: "Shelbyville",
          cidr: "10.0.9.0/24",
          gateway: nil,
          domain: nil
        )
      )
      |> Snapshot.put(
        :devices,
        Fixtures.device(
          interfaces: [
            Fixtures.interface(network_id: "shelbyville", ip: "10.0.9.5", dns_names: ["homer"])
          ]
        )
      )
      |> Snapshot.put(
        :devices,
        Fixtures.device(
          id: "tv-living-room",
          name: "TV Living Room",
          kind: :media,
          location_id: "living-room",
          interfaces: [
            Fixtures.interface(
              mac: "02:00:00:00:00:20",
              ip: "10.0.0.20",
              name: nil,
              dns_names: ["tv-living-room"]
            )
          ]
        )
      )

    [alias_parent | other_overrides] = OpnsenseClient.host_overrides()

    aliased =
      Map.put(alias_parent, "_children", [
        %{"hostname" => "TV-Living-Room", "domain" => "springfield.lan"}
      ])

    plan =
      snapshot
      |> DesiredState.build()
      |> plan(%{rows() | host_overrides: [aliased | other_overrides]})

    assert "reservation of 02:00:00:00:07:42: no Kea subnet for 10.0.9.0/24" in plan.skipped
    assert "homer: no domain, Unbound host overrides need one" in plan.skipped

    assert "tv-living-room.springfield.lan: already an Unbound alias, left untouched" in plan.skipped

    refute Enum.any?(plan.operations, &(&1.summary =~ "tv-living-room.springfield.lan"))
  end

  test "applies the operations then reconfigures the touched services" do
    desired_state = desired_state_for("smithers")

    assert {:ok, %PushReport{failures: []}} = Opnsense.push(config([]), desired_state)

    assert_received {:opnsense_post, "/api/kea/dhcpv4/set_reservation/smithers", _body}

    assert_received {:opnsense_post, "/api/unbound/settings/set_host_override/smithers-wrong",
                     _body}

    assert_received {:opnsense_post, "/api/kea/service/reconfigure", %{}}
    assert_received {:opnsense_post, "/api/unbound/service/reconfigure", %{}}
  end

  test "a device already in sync writes nothing" do
    desired_state = desired_state_for("lisa-laptop")

    assert {:ok, %PushReport{operations: []} = report} =
             Opnsense.push(config([]), desired_state)

    assert "already up to date" == PushReport.summary(report)
    refute_received {:opnsense_post, _path, _body}
  end

  test "rejected writes are reported without blocking the other service" do
    desired_state = desired_state_for("smithers")

    assert {:ok,
            %PushReport{failures: [kea: {:rejected, "update reservation" <> _rest, _response}]} =
              report} =
             Opnsense.push(config(url: "https://rejecting.example"), desired_state)

    assert ["update host override smithers.springfield.lan: 10.0.0.10 → 10.0.0.11"] ==
             summaries(report)

    assert_received {:opnsense_post, "/api/unbound/service/reconfigure", %{}}
  end

  test "Kea is pushed even when Unbound cannot be read" do
    desired_state = desired_state_for("smithers")

    assert {:ok, %PushReport{failures: [unbound: {:http_status, _path, 403}]} = report} =
             Opnsense.push(config(url: "https://kea-only.example"), desired_state)

    assert [
             "update reservation 02:00:00:00:00:11: ip 10.0.0.99 → 10.0.0.11; description none → Smithers (eth0)"
           ] ==
             summaries(report)

    assert_received {:opnsense_post, "/api/kea/dhcpv4/set_reservation/smithers", _body}
    assert_received {:opnsense_post, "/api/kea/service/reconfigure", %{}}
    refute_received {:opnsense_post, "/api/unbound/" <> _rest, _body}
  end

  test "Unbound is not read when there is no name to write" do
    snapshot =
      Snapshot.put(
        Fixtures.snapshot(),
        :networks,
        Fixtures.network(domain: nil)
      )

    desired_state = DesiredState.for_device(DesiredState.build(snapshot), "smithers")

    assert {:ok, %PushReport{failures: []}} =
             Opnsense.push(config(url: "https://kea-only.example"), desired_state)
  end

  test "discovery keeps Kea when Unbound cannot be read" do
    assert {:ok, report} = Opnsense.discover(config(url: "https://kea-only.example"))
    assert [unbound: {:http_status, _path, 403}] = report.failures
    assert %{kea_subnet: 2, kea_reservation: 4, opnsense_gateway: 2} == report.counts
  end

  test "a name duplicated in Unbound is reported, never written" do
    duplicate = %{
      "uuid" => "smithers-again",
      "hostname" => "smithers",
      "domain" => "springfield.lan",
      "rr" => "A",
      "server" => "10.0.0.11",
      "description" => "old"
    }

    plan =
      Push.plan_unbound(desired_state_for("smithers"), %{
        host_overrides: [duplicate | OpnsenseClient.host_overrides()]
      })

    assert [] == plan.operations

    assert [
             "smithers.springfield.lan: 2 host overrides in Unbound, left untouched until fixed in OPNsense"
           ] ==
             plan.skipped
  end

  test "releasing MAC addresses deletes their Kea reservations only" do
    plan = Push.plan_kea_release(["02:00:00:00:05:01", "02-00-00-00-00-11"], rows())

    assert [
             "delete reservation 02:00:00:00:00:11 → 10.0.0.99 (smithers)",
             "delete reservation 02:00:00:00:05:01 → 10.0.0.50 (moe-pc)"
           ] == summaries(plan)

    assert ["/api/kea/dhcpv4/del_reservation/smithers", "/api/kea/dhcpv4/del_reservation/moe"] ==
             Enum.map(plan.operations, & &1.path)
  end

  test "release/2 deletes nothing by default" do
    assert {:ok, %PushReport{operations: [], skipped: [_kept]}} =
             Opnsense.release(config([]), ["02:00:00:00:05:01"])

    refute_received {:opnsense_post, _path, _body}
  end

  test "release/2 deletes the reservations then reconfigures Kea when enabled" do
    assert {:ok, %PushReport{operations: [%{action: :delete}]}} =
             Opnsense.release(config(delete_reservation: :interface_deletion), [
               "02:00:00:00:05:01"
             ])

    assert_received {:opnsense_post, "/api/kea/dhcpv4/del_reservation/moe", %{}}
    assert_received {:opnsense_post, "/api/kea/service/reconfigure", %{}}
    refute_received {:opnsense_post, "/api/unbound/" <> _rest, _body}
  end

  test "release/2 writes nothing when no reservation holds the MAC addresses" do
    assert {:ok, %PushReport{operations: [], skipped: []}} =
             Opnsense.release(config(delete_reservation: :interface_deletion), [
               "02:00:00:00:0b:0b"
             ])

    refute_received {:opnsense_post, _path, _body}
  end
end
