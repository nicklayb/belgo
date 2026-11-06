defmodule Belgo.Inventory.VirtualIpTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.Observation
  alias Belgo.Fixtures
  alias Belgo.Inventory.Audit
  alias Belgo.Inventory.Codec
  alias Belgo.Inventory.References
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.VirtualIp
  alias Belgo.Providers.Opnsense.Push
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.DesiredState.DnsRecord

  test "the changeset requires an address and normalises DNS names" do
    assert {:ok,
            %VirtualIp{id: "kwik-e-mart", kind: :metallb, dns_names: ["squishee", "apu.lan"]}} =
             Codec.decode(:virtual_ips, %{
               "name" => "Kwik-E-Mart",
               "ip" => "10.0.0.110",
               "dns_names" => "Squishee, apu.lan, squishee"
             })

    assert {:error, changeset} = Codec.decode(:virtual_ips, %{"name" => "Kwik-E-Mart"})
    assert %{ip: ["can't be blank"]} = errors(changeset)

    assert {:error, changeset} =
             Codec.decode(:virtual_ips, %{
               "name" => "Moe",
               "ip" => "10.0.0.5",
               "dns_names" => "*.tavern"
             })

    assert %{dns_names: [_message]} = errors(changeset)
  end

  test "DNS names become records owned by the virtual IP, completed with the network domain" do
    desired_state = DesiredState.build(Fixtures.snapshot_with_virtual_ips())

    assert [
             %DnsRecord{
               name: "apu.kwik-e-mart.lan",
               host: "apu",
               domain: "kwik-e-mart.lan",
               address: "10.0.0.110",
               virtual_ip_id: "kwik-e-mart",
               device_id: nil
             },
             %DnsRecord{name: "squishee.springfield.lan", host: "squishee"}
           ] =
             desired_state
             |> DesiredState.for_owner({:virtual_ips, "kwik-e-mart"})
             |> Map.fetch!(:dns_records)

    assert %DesiredState{dhcp_reservations: [], clients: [], client_names: []} =
             DesiredState.for_owner(desired_state, {:virtual_ips, "kwik-e-mart"})

    refute Enum.any?(
             DesiredState.for_device(desired_state, "burns-node").dns_records,
             &(&1.virtual_ip_id != nil)
           )
  end

  test "an address shared with an interface is an error on both" do
    snapshot = Fixtures.snapshot_with_virtual_ips([Fixtures.virtual_ip(ip: "10.0.0.10")])
    issues = Audit.issues(snapshot)

    assert [%{severity: :error, message: "IP address 10.0.0.10 is also used by Burns Node"}] =
             Audit.issues_for(issues, :virtual_ips, "kwik-e-mart")

    assert Enum.any?(
             Audit.issues_for(issues, :devices, "burns-node"),
             &(&1.message == "IP address 10.0.0.10 is also used by Kwik-E-Mart")
           )
  end

  test "unknown owner, address outside its network and DHCP range are reported" do
    snapshot =
      Fixtures.snapshot_with_virtual_ips([
        Fixtures.virtual_ip(owner_id: "mr-burns-yacht"),
        Fixtures.virtual_ip(
          id: "lard-lad",
          name: "Lard Lad",
          ip: "10.9.0.1",
          network_id: "springfield",
          dns_names: []
        ),
        Fixtures.virtual_ip(id: "krusty", name: "Krusty", ip: "10.0.0.150", dns_names: [])
      ])

    snapshot = %{
      snapshot
      | networks: [Fixtures.network(dhcp_start: "10.0.0.100", dhcp_end: "10.0.0.199")]
    }

    issues = Audit.issues(snapshot)

    assert Enum.any?(
             Audit.issues_for(issues, :virtual_ips, "kwik-e-mart"),
             &(&1.message == "unknown device mr-burns-yacht")
           )

    assert [%{message: "10.9.0.1 is outside of Springfield (10.0.0.0/24)"}] =
             Audit.issues_for(issues, :virtual_ips, "lard-lad")

    assert [%{severity: :warning, message: message}] =
             Audit.issues_for(issues, :virtual_ips, "krusty")

    assert message =~ "DHCP range"
  end

  test "a DNS name used by a device and a virtual IP is an error on both" do
    snapshot =
      Fixtures.snapshot_with_virtual_ips([Fixtures.virtual_ip(dns_names: ["smithers"])])

    issues = Audit.issues(snapshot)

    assert Enum.any?(
             Audit.issues_for(issues, :virtual_ips, "kwik-e-mart"),
             &(&1.message == "DNS name smithers.springfield.lan is also used by Smithers")
           )

    assert Enum.any?(
             Audit.issues_for(issues, :devices, "smithers"),
             &(&1.message == "DNS name smithers.springfield.lan is also used by Kwik-E-Mart")
           )
  end

  test "the owner device and the network cannot be deleted while referenced" do
    snapshot =
      Fixtures.snapshot_with_virtual_ips([Fixtures.virtual_ip(network_id: "springfield")])

    assert {:virtual_ips, "kwik-e-mart", "Kwik-E-Mart"} in References.list(
             snapshot,
             :devices,
             "burns-node"
           )

    assert {:virtual_ips, "kwik-e-mart", "Kwik-E-Mart"} in References.list(
             snapshot,
             :networks,
             "springfield"
           )
  end

  describe "discovery" do
    test "a client seen on the virtual IP with a node MAC is the virtual IP, not that node" do
      observations = [
        # MetalLB L2: Burns Node answers ARP for the virtual IP with its own MAC.
        %Observation{
          provider: :adguard,
          source: :adguard_auto_client,
          kind: :device,
          ip: "10.0.0.110",
          mac: "02:00:00:00:00:10",
          hostname: "squishee"
        },
        %Observation{
          provider: :opnsense,
          source: :unbound_host_override,
          kind: :device,
          ip: "10.0.0.110",
          hostname: "squishee",
          domain: "springfield.lan"
        }
      ]

      correlation = Correlation.build(Fixtures.snapshot_with_virtual_ips(), observations)

      assert [] == correlation.unknown_devices
      assert [] == correlation.divergences
      assert [] == correlation.dns_names
    end

    test "an Unbound override without host names its domain" do
      observations = [
        %Observation{
          provider: :opnsense,
          source: :unbound_host_override,
          kind: :device,
          ip: "10.0.0.110",
          domain: "k8s.springfield.lan"
        }
      ]

      correlation = Correlation.build(Fixtures.snapshot_with_virtual_ips(), observations)

      assert [%{message: "k8s.springfield.lan resolves to 10.0.0.110, unknown to Belgo"}] =
               correlation.divergences
    end

    test "unknown names on the virtual IP are suggested for it" do
      observations = [
        %Observation{
          provider: :opnsense,
          source: :unbound_host_override,
          kind: :device,
          ip: "10.0.0.110",
          hostname: "itchy",
          domain: "springfield.lan"
        }
      ]

      correlation = Correlation.build(Fixtures.snapshot_with_virtual_ips(), observations)

      assert [%{name: "itchy.springfield.lan", virtual_ip_id: "kwik-e-mart", device_id: nil}] =
               correlation.dns_names

      assert [
               %{
                 collection: :virtual_ips,
                 id: "kwik-e-mart",
                 message: "itchy.springfield.lan resolves to 10.0.0.110, unknown to Belgo"
               }
             ] = correlation.divergences
    end
  end

  test "virtual IPs have their own collection" do
    assert :virtual_ips in Snapshot.collections()
    assert VirtualIp == Snapshot.schema(:virtual_ips)
  end

  defp errors(changeset),
    do: Ecto.Changeset.traverse_errors(changeset, fn {message, _options} -> message end)

  test "its DNS names are pushed as Unbound host overrides, never as DHCP" do
    desired_state =
      Fixtures.snapshot_with_virtual_ips()
      |> DesiredState.build()
      |> DesiredState.for_owner({:virtual_ips, "kwik-e-mart"})

    existing = %{
      "uuid" => "squishee-uuid",
      "hostname" => "squishee",
      "domain" => "springfield.lan",
      "rr" => "A (IPv4 address)",
      "server" => "10.0.0.99"
    }

    assert %{operations: [create, update], skipped: []} =
             Push.plan_unbound(desired_state, %{host_overrides: [existing]})

    assert %{action: :create, body: %{"host" => %{"hostname" => "apu", "server" => "10.0.0.110"}}} =
             create

    assert %{action: :update, path: "/api/unbound/settings/set_host_override/squishee-uuid"} =
             update

    assert %{operations: []} = Push.plan_kea(desired_state, %{subnets: [], reservations: []})
  end
end
