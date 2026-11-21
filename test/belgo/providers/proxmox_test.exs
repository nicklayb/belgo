defmodule Belgo.Providers.ProxmoxTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Report
  alias Belgo.Discovery.Workload
  alias Belgo.Discovery.Workload.HostReference
  alias Belgo.Fixtures.ProxmoxClient
  alias Belgo.Providers.Proxmox
  alias Belgo.Providers.Proxmox.Translate

  @environment %{
    "BELGO_PROXMOX_TOKEN_ID" => "burns@pve!excellent",
    "BELGO_PROXMOX_TOKEN_SECRET" => "release-the-hounds"
  }

  defp config(url \\ "https://pve.springfield.lan:8006") do
    %Proxmox.Config{
      url: url,
      token_id: "burns@pve!excellent",
      token_secret: "release-the-hounds",
      client: ProxmoxClient
    }
  end

  test "parses its configuration, both token parts required" do
    assert {:ok,
            %Proxmox.Config{
              url: "https://pve.springfield.lan:8006",
              token_id: "burns@pve!excellent",
              verify_tls: false
            }} =
             Proxmox.parse_config(
               %{"url" => "https://pve.springfield.lan:8006/", "verify_tls" => false},
               @environment
             )

    assert {:error, messages} =
             Proxmox.parse_config(%{"url" => "https://pve", "node" => "x"}, %{})

    assert "missing secret: set BELGO_PROXMOX_TOKEN_ID or BELGO_PROXMOX_TOKEN_ID_FILE" in messages
    assert Enum.any?(messages, &(&1 =~ "unknown options: node"))
    refute function_exported?(Proxmox, :push, 2)
  end

  test "hides the token when inspected" do
    refute inspect(config()) =~ "release-the-hounds"
  end

  describe "Translate" do
    test "keeps VMs and containers, not templates" do
      assert ["qemu/101", "qemu/102", "lxc/200"] =
               Enum.map(Translate.guests(ProxmoxClient.resources()), & &1["id"])
    end

    test "reads MAC addresses of VM and container network devices in order" do
      assert Translate.mac_addresses(ProxmoxClient.smithers_config()) == [
               "02:00:00:00:00:11",
               "02:00:00:00:0a:11"
             ]

      assert Translate.mac_addresses(%{
               "net0" => "name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:00:01,ip=dhcp",
               "net2" => "model=virtio,macaddr=BC:24:11:00:00:02",
               "net10" => "bridge=vmbr0"
             }) == ["bc:24:11:00:00:01", "bc:24:11:00:00:02"]

      assert Translate.mac_addresses(nil) == []
    end

    test "node addresses come from the cluster status" do
      assert Translate.node_addresses(ProxmoxClient.status()) == %{
               "burns" => "10.0.0.10",
               "flanders" => "10.0.0.30"
             }
    end

    test "config paths encode the node" do
      assert Translate.config_path(%{"node" => "burns", "type" => "lxc", "vmid" => 200}) ==
               "/nodes/burns/lxc/200/config"
    end
  end

  describe "discover/1" do
    test "reports guests with their MACs and node" do
      assert {:ok, %Report{provider: :proxmox, workloads: workloads, failures: []} = report} =
               Proxmox.discover(config())

      assert report.counts == %{proxmox_vm: 2, proxmox_lxc: 1}

      assert [
               %Workload{
                 kind: :virtual_machine,
                 name: "Smithers-VM",
                 reference: "qemu/101",
                 status: "running",
                 macs: ["02:00:00:00:00:11", "02:00:00:00:0a:11"],
                 host: %HostReference{name: "flanders", ips: ["10.0.0.30"]}
               },
               %Workload{name: "Duffman", status: "stopped", macs: ["02:00:00:00:0d:0f"]},
               %Workload{kind: :lxc, name: "Itchy-CT", macs: ["02:00:00:00:02:00"]}
             ] = workloads
    end

    test "node addresses and configurations are best effort" do
      assert {:ok, %Report{workloads: workloads, failures: failures}} =
               Proxmox.discover(config("https://status-broken.example"))

      assert [
               nodes: {:http_status, "/cluster/status", 403},
               config: {"/nodes/burns/lxc/200/config", _reason}
             ] =
               failures

      assert %Workload{macs: [], host: %HostReference{ips: []}} =
               Enum.find(workloads, &(&1.name == "Itchy-CT"))
    end

    test "fails when the guest list cannot be read" do
      assert {:error, {:http_status, "/cluster/resources?type=vm", 401}} =
               Proxmox.discover(config("https://broken.example"))
    end
  end
end
