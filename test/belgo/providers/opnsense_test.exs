defmodule Belgo.Providers.OpnsenseTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Observation
  alias Belgo.Discovery.Report
  alias Belgo.Fixtures.OpnsenseClient
  alias Belgo.Providers.Opnsense
  alias Belgo.Providers.Opnsense.Translate

  defp config(url \\ "https://opnsense.springfield.lan") do
    %Opnsense.Config{url: url, api_key: "homer", api_secret: "donuts", client: OpnsenseClient}
  end

  test "translates subnets into networks" do
    assert [springfield, shelbyville] = Translate.subnets(OpnsenseClient.subnets())

    assert %Observation{
             kind: :network,
             cidr: "10.0.0.0/24",
             gateway: "10.0.0.1",
             domain: "springfield.lan"
           } = springfield

    assert %Observation{
             cidr: "10.0.5.0/24",
             domain: nil,
             description: "Shelbyville",
             dhcp_start: "10.0.5.100",
             dhcp_end: "10.0.5.199"
           } = shelbyville

    assert %Observation{dhcp_start: nil, dhcp_end: nil} = springfield
  end

  test "translates reservations, normalising MACs and resolving the subnet uuid" do
    [moe, smithers | _rest] =
      Translate.reservations(OpnsenseClient.reservations(), OpnsenseClient.subnets())

    assert %Observation{
             source: :kea_reservation,
             mac: "02:00:00:00:05:01",
             ip: "10.0.0.50",
             hostname: "moe-pc",
             cidr: "10.0.0.0/24"
           } = moe

    assert %Observation{mac: "02:00:00:00:00:11", description: nil} = smithers
  end

  test "reservations may reference their subnet by CIDR" do
    [row | _rest] = OpnsenseClient.reservations()

    assert [%Observation{cidr: "10.0.0.0/24"}] =
             Translate.reservations([%{row | "subnet" => "10.0.0.0/24"}], [])
  end

  test "keeps only address host overrides" do
    observations = Translate.host_overrides(OpnsenseClient.host_overrides())

    assert [
             "assistant.springfield.lan",
             "moe-pc.springfield.lan",
             "smithers.springfield.lan",
             "tavern.springfield.lan"
           ] ==
             observations
             |> Enum.map(&Observation.fqdn/1)
             |> Enum.sort()
  end

  test "discover/1 reports every observation" do
    assert {:ok, %Report{provider: :opnsense, counts: counts}} = Opnsense.discover(config())

    assert %{kea_subnet: 2, kea_reservation: 4, unbound_host_override: 4, opnsense_gateway: 2} ==
             counts
  end

  test "discover/1 fails when every service fails" do
    assert {:error, [kea: {:http_status, _kea_path, 401}, unbound: {:http_status, _path, 401}]} =
             Opnsense.discover(config("https://broken.example"))
  end

  test "OPNsense announces itself as the gateway of its subnets" do
    assert [
             %Observation{
               source: :opnsense_gateway,
               role: :gateway,
               identity: "opnsense-gateway",
               ip: "10.0.0.1",
               description: "OPNsense"
             },
             %Observation{ip: "10.0.5.1", identity: "opnsense-gateway"}
           ] = Translate.gateway(OpnsenseClient.subnets())
  end

  test "the gateway addresses make a single discovered device" do
    snapshot = Belgo.Inventory.Snapshot.delete(Belgo.Fixtures.snapshot(), :devices, "power-plant")

    snapshot =
      Belgo.Inventory.Snapshot.put(
        snapshot,
        :devices,
        Belgo.Fixtures.device(id: "plow-king", name: "Plow King", kind: :network)
      )

    {:ok, report} = Opnsense.discover(config())
    correlation = Belgo.Discovery.Correlation.build(snapshot, report.observations)

    gateways = Enum.filter(correlation.unknown_devices, &(&1.role == :gateway))

    assert [%{ips: ["10.0.0.1", "10.0.5.1"], description: "OPNsense"}] = gateways
  end

  test "host overrides are address records whatever the form of their type" do
    assert Translate.address_record?(%{"rr" => "A"})
    assert Translate.address_record?(%{"rr" => "A (IPv4 address)"})
    assert Translate.address_record?(%{"rr" => "AAAA (IPv6 address)"})
    assert Translate.address_record?(%{})
    refute Translate.address_record?(%{"rr" => "MX (Mail server)"})
    refute Translate.address_record?(%{"rr" => "MX"})
  end

  test "delete_reservation defaults to never and accepts interface_deletion only" do
    environment = %{"BELGO_OPNSENSE_API_KEY" => "homer", "BELGO_OPNSENSE_API_SECRET" => "donuts"}

    assert {:ok, %{delete_reservation: :never}} =
             Opnsense.parse_config(%{"url" => "https://opnsense"}, environment)

    assert {:ok, %{delete_reservation: :interface_deletion}} =
             Opnsense.parse_config(
               %{"url" => "https://opnsense", "delete_reservation" => "interface_deletion"},
               environment
             )

    assert {:error, ["delete_reservation must be interface_deletion or never"]} =
             Opnsense.parse_config(
               %{"url" => "https://opnsense", "delete_reservation" => "always"},
               environment
             )
  end
end
