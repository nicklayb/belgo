defmodule Belgo.Discovery.CorrelationTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.Suggestion
  alias Belgo.Fixtures
  alias Belgo.Fixtures.OpnsenseClient
  alias Belgo.Inventory.DeniedDevice
  alias Belgo.Inventory.Snapshot
  alias Belgo.Providers.Opnsense

  setup do
    config = %Opnsense.Config{
      url: "https://opnsense",
      api_key: "homer",
      api_secret: "donuts",
      client: OpnsenseClient
    }

    {:ok, report} = Opnsense.discover(config)
    {:ok, observations: report.observations}
  end

  test "merges observations sharing an address into unknown devices", %{
    observations: observations
  } do
    correlation = Correlation.build(Fixtures.snapshot(), observations)

    assert ["moe-pc", "nelson-iphone"] == Enum.map(correlation.unknown_devices, & &1.hostname)
    [moe | _nelson] = correlation.unknown_devices

    assert "mac-02-00-00-00-05-01" == moe.id
    assert ["10.0.0.50"] == moe.ips

    assert [:kea_reservation, :unbound_host_override, :unbound_host_override] ==
             Enum.map(moe.observations, & &1.source)
  end

  test "suggests new networks only", %{observations: observations} do
    correlation = Correlation.build(Fixtures.snapshot(), observations)

    assert [
             %Correlation.DiscoveredNetwork{
               id: "10-0-5-0-24",
               cidr: "10.0.5.0/24",
               gateway: "10.0.5.1"
             }
           ] =
             correlation.new_networks
  end

  test "reports divergences of claimed records", %{observations: observations} do
    correlation = Correlation.build(Fixtures.snapshot(), observations)

    assert [
             "reservation description is empty, Belgo has Smithers (eth0)",
             "reservation of 02:00:00:00:00:11 uses 10.0.0.99, Belgo has 10.0.0.11",
             "smithers.springfield.lan resolves to 10.0.0.10, Belgo expects 10.0.0.11"
           ] ==
             correlation
             |> Correlation.divergences_for(:devices, "smithers")
             |> Enum.map(& &1.message)

    assert [
             "reservation description is empty, Belgo has Burns Node (eth0)",
             "smithers.springfield.lan resolves to 10.0.0.10, Belgo expects 10.0.0.11"
           ] ==
             correlation
             |> Correlation.divergences_for(:devices, "burns-node")
             |> Enum.map(& &1.message)

    assert [] == Correlation.divergences_for(correlation, :networks, "springfield")
  end

  test "denied MAC addresses are ignored", %{observations: observations} do
    snapshot =
      Snapshot.put(Fixtures.snapshot(), :denylist, %DeniedDevice{id: "02:00:00:00:06:66"})

    correlation = Correlation.build(snapshot, observations)

    assert ["moe-pc"] == Enum.map(correlation.unknown_devices, & &1.hostname)
    assert ["nelson-iphone"] == Enum.map(correlation.ignored_devices, & &1.hostname)
  end

  test "claiming a suggestion removes it", %{observations: observations} do
    snapshot = Fixtures.snapshot()

    {:ok, moe} =
      snapshot
      |> Correlation.build(observations)
      |> Correlation.fetch_device("mac-02-00-00-00-05-01")

    params = Suggestion.device_params(moe, snapshot)
    changeset = Belgo.Inventory.Changes.build(snapshot, :devices, nil, params)
    {:ok, device} = Ecto.Changeset.apply_action(changeset, :insert)

    correlation =
      snapshot
      |> Snapshot.put(:devices, device)
      |> Correlation.build(observations)

    assert ["nelson-iphone"] == Enum.map(correlation.unknown_devices, & &1.hostname)

    assert ["reservation description is Moe's PC, Belgo has moe-pc"] ==
             Enum.map(Correlation.divergences_for(correlation, :devices, "moe-pc"), & &1.message)
  end

  test "suggested params prefill the device form", %{observations: observations} do
    snapshot = Fixtures.snapshot()

    {:ok, moe} =
      snapshot
      |> Correlation.build(observations)
      |> Correlation.fetch_device("mac-02-00-00-00-05-01")

    assert %{
             "name" => "moe-pc",
             "hostname" => "moe-pc",
             "notes" => "Moe's PC",
             "interfaces" => %{
               "0" => %{
                 "mac" => "02:00:00:00:05:01",
                 "ip" => "10.0.0.50",
                 "assignment" => "reserved",
                 "network_id" => "springfield",
                 "dns_names" => "moe-pc, tavern"
               }
             }
           } = Suggestion.device_params(moe, snapshot)
  end

  test "is deterministic", %{observations: observations} do
    assert Correlation.build(Fixtures.snapshot(), observations) ==
             Correlation.build(Fixtures.snapshot(), Enum.reverse(observations))
  end

  test "unknown devices outside the DHCP range of their network are listed apart", %{
    observations: observations
  } do
    snapshot =
      Snapshot.put(
        Fixtures.snapshot(),
        :networks,
        Fixtures.network(dhcp_start: "10.0.0.60", dhcp_end: "10.0.0.99")
      )

    correlation = Correlation.build(snapshot, observations)

    assert ["moe-pc"] == Enum.map(correlation.out_of_dhcp_devices, & &1.hostname)
    assert ["nelson-iphone"] == Enum.map(correlation.unknown_devices, & &1.hostname)
    assert {:ok, _moe} = Correlation.fetch_device(correlation, "mac-02-00-00-00-05-01")
  end

  test "without a DHCP range, nothing is out of DHCP", %{observations: observations} do
    assert [] == Correlation.build(Fixtures.snapshot(), observations).out_of_dhcp_devices
  end

  test "a network without range uses the range reported by OPNsense", %{
    observations: observations
  } do
    snapshot =
      Snapshot.put(
        Fixtures.snapshot(),
        :networks,
        Fixtures.network(
          id: "shelbyville",
          name: "Shelbyville",
          cidr: "10.0.5.0/24",
          gateway: "10.0.5.1"
        )
      )

    correlation = Correlation.build(snapshot, observations)

    assert %{"shelbyville" => %{start: "10.0.5.100", end: "10.0.5.199", source: :opnsense}} ==
             correlation.dhcp_ranges

    assert [] == Correlation.divergences_for(correlation, :networks, "shelbyville")
  end

  test "a range defined in Belgo wins and differences are divergences", %{
    observations: observations
  } do
    snapshot =
      Snapshot.put(
        Fixtures.snapshot(),
        :networks,
        Fixtures.network(
          id: "shelbyville",
          name: "Shelbyville",
          cidr: "10.0.5.0/24",
          gateway: "10.0.5.1",
          domain: nil,
          dhcp_start: "10.0.5.50",
          dhcp_end: "10.0.5.60"
        )
      )

    correlation = Correlation.build(snapshot, observations)

    assert %{start: "10.0.5.50", source: :inventory} = correlation.dhcp_ranges["shelbyville"]

    assert ["dhcp range is 10.0.5.100–10.0.5.199, Belgo has 10.0.5.50–10.0.5.60"] ==
             Enum.map(
               Correlation.divergences_for(correlation, :networks, "shelbyville"),
               & &1.message
             )
  end

  test "duplicated Unbound names are conflicts, attached to the device owning the name", %{
    observations: observations
  } do
    duplicate = %{
      List.first(Enum.filter(observations, &(&1.source == :unbound_host_override)))
      | ip: "10.0.0.66",
        reference: "again"
    }

    stray = %{duplicate | hostname: "krusty", ip: "10.0.0.70", reference: "krusty-1"}
    stray_again = %{stray | ip: "10.0.0.71", reference: "krusty-2", description: "Krusty"}

    smithers = %{
      duplicate
      | hostname: "smithers",
        ip: "10.0.0.12",
        reference: "smithers-again",
        description: "old"
    }

    correlation =
      Correlation.build(Fixtures.snapshot(), observations ++ [smithers, stray, stray_again])

    assert [
             %{name: "krusty.springfield.lan", owner_id: nil},
             %{name: "smithers.springfield.lan", owner_id: "smithers"}
           ] =
             correlation.conflicts

    assert [
             %{
               name: "krusty.springfield.lan",
               message:
                 "krusty.springfield.lan has 2 Unbound host overrides: 10.0.0.70, 10.0.0.71 (Krusty)"
             }
           ] =
             Correlation.unowned_conflicts(correlation)

    assert "smithers.springfield.lan has 2 Unbound host overrides: 10.0.0.10, 10.0.0.12 (old)" in Enum.map(
             Correlation.divergences_for(correlation, :devices, "smithers"),
             & &1.message
           )
  end
end
