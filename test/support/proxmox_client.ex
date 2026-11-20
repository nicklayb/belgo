defmodule Belgo.Fixtures.ProxmoxClient do
  @moduledoc """
  Proxmox VE client answering a Springfield cluster: nodes `burns` (10.0.0.10) and
  `flanders` (10.0.0.30). Smithers' VM runs on `flanders`, the unknown `Duffman` VM
  and the `Itchy-CT` container on `burns`, a template is ignored. The
  `broken.example` instance fails every call; `status-broken.example` fails
  `/cluster/status` and the configuration of `Itchy-CT`.
  """

  @behaviour Belgo.Providers.Proxmox.Client

  @impl Belgo.Providers.Proxmox.Client
  def get(%{url: "https://broken.example"}, path), do: {:error, {:http_status, path, 401}}

  def get(%{url: "https://status-broken.example"}, "/cluster/status" = path),
    do: {:error, {:http_status, path, 403}}

  def get(%{url: "https://status-broken.example"}, "/nodes/burns/lxc/200/config" = path),
    do: {:error, {:http_status, path, 403}}

  def get(_config, "/cluster/status"), do: {:ok, status()}
  def get(_config, "/cluster/resources?type=vm"), do: {:ok, resources()}
  def get(_config, "/nodes/flanders/qemu/101/config"), do: {:ok, smithers_config()}

  def get(_config, "/nodes/burns/qemu/102/config"),
    do: {:ok, %{"net0" => "e1000=02:00:00:00:0D:0F,bridge=vmbr0"}}

  def get(_config, "/nodes/burns/lxc/200/config"),
    do: {:ok, %{"net0" => "name=eth0,bridge=vmbr0,hwaddr=02:00:00:00:02:00,ip=dhcp,type=veth"}}

  @doc "`/cluster/status` rows."
  def status do
    [
      %{"type" => "cluster", "name" => "Springfield", "quorate" => 1},
      %{"type" => "node", "name" => "burns", "ip" => "10.0.0.10", "online" => 1},
      %{"type" => "node", "name" => "flanders", "ip" => "10.0.0.30", "online" => 1}
    ]
  end

  @doc "`/cluster/resources?type=vm` rows."
  def resources do
    [
      %{
        "id" => "qemu/101",
        "vmid" => 101,
        "name" => "Smithers-VM",
        "node" => "flanders",
        "type" => "qemu",
        "status" => "running",
        "template" => 0
      },
      %{
        "id" => "qemu/102",
        "vmid" => 102,
        "name" => "Duffman",
        "node" => "burns",
        "type" => "qemu",
        "status" => "stopped"
      },
      %{
        "id" => "lxc/200",
        "vmid" => 200,
        "name" => "Itchy-CT",
        "node" => "burns",
        "type" => "lxc",
        "status" => "running"
      },
      %{
        "id" => "qemu/9000",
        "vmid" => 9000,
        "name" => "Template",
        "node" => "burns",
        "type" => "qemu",
        "status" => "stopped",
        "template" => 1
      }
    ]
  end

  @doc "Configuration of Smithers' VM: two network devices, the first one known."
  def smithers_config do
    %{
      "name" => "Smithers-VM",
      "net1" => "virtio=02:00:00:00:0A:11,bridge=vmbr1",
      "net0" => "virtio=02:00:00:00:00:11,bridge=vmbr0,firewall=1",
      "smbios1" => "uuid=0b0e7d9c-1895-4f2a-9d3c-000000000011"
    }
  end
end
