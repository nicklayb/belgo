defmodule Belgo.Providers.OmadaTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.Observation
  alias Belgo.Discovery.Suggestion
  alias Belgo.Fixtures
  alias Belgo.Fixtures.OmadaClient
  alias Belgo.Inventory.Snapshot
  alias Belgo.Providers.Omada
  alias Belgo.Providers.Omada.Push
  alias Belgo.Providers.Omada.Translate
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.PushReport

  defp config(url \\ "https://omada.springfield.lan:8043") do
    %Omada.Config{url: url, client_id: "ned", client_secret: "okilydokily", client: OmadaClient}
  end

  defp observations do
    {:ok, report} = Omada.discover(config())
    report.observations
  end

  test "parses its configuration, with the Default site" do
    environment = %{
      "BELGO_OMADA_CLIENT_ID" => "ned",
      "BELGO_OMADA_CLIENT_SECRET" => "okilydokily"
    }

    assert {:ok, %Omada.Config{site: "Default", url: "https://omada:8043"}} =
             Omada.parse_config(%{"url" => "https://omada:8043/"}, environment)

    assert {:ok, %Omada.Config{site: "Home", omada_id: "de382a0e"}} =
             Omada.parse_config(
               %{"url" => "https://omada", "site" => "Home", "omada_id" => "de382a0e"},
               environment
             )
  end

  test "site devices are network devices with their uplink" do
    {:ok, devices} = OmadaClient.devices(%{})

    assert [
             %Observation{
               role: :gateway,
               mac: "aa:00:00:00:00:01",
               description: "Omada Gateway",
               uplink_mac: nil
             },
             %Observation{
               role: :switch,
               uplink_mac: "aa:00:00:00:00:01",
               uplink_name: "Omada Gateway",
               uplink_port: "3"
             },
             %Observation{
               role: :access_point,
               ip: "10.0.0.4",
               uplink_mac: "aa:00:00:00:00:02",
               uplink_port: "8"
             }
           ] = Translate.devices(devices)
  end

  test "clients carry their current uplink, Wi-Fi details and AP lock" do
    {:ok, clients} = OmadaClient.clients(%{})

    assert [
             %Observation{
               mac: "02:00:00:00:00:77",
               hostname: "homepod-mini",
               description: "HomePod Mini",
               wireless: true,
               uplink_mac: "aa:00:00:00:00:03",
               ssid: "Springfield",
               locked_to_ap: true
             },
             %Observation{
               mac: "02:00:00:00:00:10",
               wireless: false,
               uplink_mac: "aa:00:00:00:00:02",
               uplink_port: "5"
             },
             %Observation{mac: "02:00:00:00:00:30", description: nil, locked_to_ap: false}
           ] = Translate.clients(clients)
  end

  test "discover/1 reports a refused token" do
    assert {:error, {:omada_error, -44_106, _message}} =
             Omada.discover(config("https://broken.example"))
  end

  test "network devices are suggested with their role, clients get their live uplink" do
    snapshot = Fixtures.snapshot()
    correlation = Correlation.build(snapshot, observations())

    {:ok, switch} = Correlation.fetch_device(correlation, "mac-aa-00-00-00-00-02")
    assert :switch == switch.role

    assert %{"name" => "Switch PoE Attic", "kind" => "network", "network_role" => "switch"} =
             Suggestion.device_params(switch, snapshot)

    assert %{
             switch_id: nil,
             switch_name: "Switch PoE Attic",
             port: "5",
             wireless?: false,
             provider: :omada
           } =
             Correlation.uplink(correlation, "burns-node")

    assert %{
             switch_name: "AP Ground Floor",
             wireless?: true,
             ssid: "Springfield",
             locked_to_ap: false
           } =
             Correlation.uplink(correlation, "lisa-laptop")

    assert "client name is Mr Burns, Belgo has Burns Node" in Enum.map(
             Correlation.divergences_for(correlation, :devices, "burns-node"),
             & &1.message
           )
  end

  test "uplinks point to the claimed switch" do
    switch =
      Fixtures.device(
        id: "switch-poe-attic",
        name: "Switch PoE Attic",
        kind: :network,
        network_role: :switch,
        interfaces: [Fixtures.interface(mac: "aa:00:00:00:00:02", ip: "10.0.0.3", name: nil)]
      )

    correlation =
      Correlation.build(Snapshot.put(Fixtures.snapshot(), :devices, switch), observations())

    assert %{switch_id: "switch-poe-attic", port: "5"} =
             Correlation.uplink(correlation, "burns-node")
  end

  test "plans renames of connected clients only" do
    {:ok, clients} = OmadaClient.clients(%{})
    plan = Push.plan(DesiredState.build(Fixtures.snapshot()), clients)

    assert [
             "rename client 02:00:00:00:00:10: Mr Burns → Burns Node",
             "rename client 02:00:00:00:00:30: 02-00-00-00-00-30 → Lisa Laptop"
           ] ==
             Enum.map(plan.operations, & &1.summary)

    assert "02:00:00:00:00:11: not connected to Omada, name not pushed" in plan.skipped
  end

  test "push/2 renames with the controller MAC format" do
    desired_state = DesiredState.for_device(DesiredState.build(Fixtures.snapshot()), "burns-node")

    assert {:ok, %PushReport{provider: :omada, operations: [_rename]}} =
             Omada.push(config(), desired_state)

    assert_received {:omada_rename, "02-00-00-00-00-10", "Burns Node"}
  end

  test "push/2 does nothing for a device without MAC address" do
    desired_state =
      DesiredState.for_device(DesiredState.build(Fixtures.snapshot()), "power-plant")

    assert {:ok, %PushReport{operations: []}} =
             Omada.push(config("https://broken.example"), desired_state)
  end

  test "a client wired on the gateway uses it as uplink" do
    client = %{
      "mac" => "02-00-00-00-00-99",
      "wireless" => false,
      "gatewayMac" => "AA-00-00-00-00-01",
      "gatewayName" => "Omada Gateway",
      "port" => 4
    }

    assert [
             %Observation{
               uplink_mac: "aa:00:00:00:00:01",
               uplink_name: "Omada Gateway",
               uplink_port: "4"
             }
           ] =
             Translate.clients([client])
  end
end
