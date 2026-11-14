defmodule Belgo.Sync.DesiredStateTest do
  use ExUnit.Case, async: true

  import Belgo.Fixtures

  alias Belgo.Inventory.Snapshot
  alias Belgo.Sync.DesiredState

  test "builds DNS records, DHCP reservations and client names" do
    desired_state = DesiredState.build(snapshot())

    assert [
             %DesiredState.DnsRecord{
               name: "assistant.springfield.lan",
               host: "assistant",
               domain: "springfield.lan",
               address: "10.0.0.11",
               description: "Smithers (eth0)",
               device_id: "smithers"
             },
             %DesiredState.DnsRecord{name: "smithers.springfield.lan", address: "10.0.0.11"}
           ] = desired_state.dns_records

    assert %DesiredState.DhcpReservation{
             mac: "02:00:00:00:00:10",
             cidr: "10.0.0.0/24",
             hostname: "burns-node",
             description: "Burns Node (eth0)"
           } =
             Enum.find(desired_state.dhcp_reservations, &(&1.device_id == "burns-node"))

    assert ["10.0.0.2", "10.0.0.10", "10.0.0.11", "10.0.0.20"] ==
             Enum.map(desired_state.dhcp_reservations, & &1.address)

    assert %DesiredState.ClientName{
             mac: "02:00:00:00:00:30",
             name: "Lisa Laptop",
             device_id: "lisa-laptop",
             kind: :laptop
           } in desired_state.client_names

    # Brand / Model metadata become the client vendor and model (labels case insensitive).
    assert %DesiredState.ClientName{kind: :server, vendor: "Excellent Computers", model: nil} =
             Enum.find(desired_state.client_names, &(&1.device_id == "burns-node"))
  end

  test "every interface shares the hostname, DNS records only come from DNS names" do
    snapshot =
      Snapshot.put(
        snapshot(),
        :devices,
        device(
          id: "homer-pc",
          name: "Homer PC",
          interfaces: [
            interface(),
            interface(
              name: "Wi-Fi",
              mac: "02:00:00:00:07:43",
              ip: "10.0.0.43",
              dns_names: ["homer-wifi"]
            )
          ]
        )
      )

    homer =
      snapshot
      |> DesiredState.build()
      |> DesiredState.for_device("homer-pc")

    assert [{"homer-pc", "10.0.0.42"}, {"homer-pc", "10.0.0.43"}] ==
             Enum.map(homer.dhcp_reservations, &{&1.hostname, &1.address})

    assert [
             {"homer-wifi.springfield.lan", "10.0.0.43"}
           ] ==
             Enum.map(homer.dns_records, &{&1.name, &1.address})

    assert ["Homer PC", "Homer PC"] == Enum.map(homer.client_names, & &1.name)
  end

  test "is deterministic" do
    assert DesiredState.build(snapshot()) == DesiredState.build(snapshot())
  end

  test "names with a dot are used as is, short ones get the network domain" do
    snapshot =
      Snapshot.put(
        snapshot(),
        :devices,
        device(interfaces: [interface(dns_names: ["duff", "duff.beer.example"])])
      )

    names =
      snapshot
      |> DesiredState.build()
      |> DesiredState.for_device("homer-pc")
      |> Map.fetch!(:dns_records)
      |> Enum.map(&{&1.name, &1.host, &1.domain})

    assert [
             {"duff.beer.example", "duff", "beer.example"},
             {"duff.springfield.lan", "duff", "springfield.lan"}
           ] == names
  end
end
