defmodule Belgo.Providers.Proxmox.Translate do
  @moduledoc """
  Turns Proxmox VE API answers into guest workloads. Pure functions.

  Fields (API viewer, `apidoc.js`): `/cluster/resources?type=vm` rows have `id`
  (`qemu/105`), `vmid`, `name`, `node`, `type` (`qemu` | `lxc`), `status`, `template`;
  `/cluster/status` rows of `type` `node` have `name` and `ip`. Guest configurations
  hold network devices as `net0`, `net1`…: `virtio=BC:24:11:…,bridge=vmbr0` for VMs
  (the model key carries the MAC, or `macaddr=`), `name=eth0,hwaddr=BC:24:11:…` for
  LXC.
  """

  alias Belgo.Discovery.Workload
  alias Belgo.Discovery.Workload.HostReference
  alias Belgo.Network.MacAddress

  @provider :proxmox
  @kind_by_type %{"qemu" => :virtual_machine, "lxc" => :lxc}
  @source_by_type %{"qemu" => :proxmox_vm, "lxc" => :proxmox_lxc}
  @network_device_key ~r/\Anet\d+\z/

  @doc "Lists the guests of `/cluster/resources?type=vm`, templates and other types left out."
  @spec guests([map()]) :: [map()]
  def guests(rows) do
    Enum.filter(rows, fn row ->
      is_map_key(@kind_by_type, row["type"]) and is_binary(row["node"]) and
        row["vmid"] != nil and row["template"] not in [1, true]
    end)
  end

  @doc "API path of a guest's configuration."
  @spec config_path(map()) :: String.t()
  def config_path(%{"node" => node, "type" => type, "vmid" => vmid}),
    do: "/nodes/#{URI.encode(node, &URI.char_unreserved?/1)}/#{type}/#{vmid}/config"

  @doc "IP address of each node, by node name, from `/cluster/status`."
  @spec node_addresses([map()]) :: %{String.t() => String.t()}
  def node_addresses(rows) do
    for %{"type" => "node", "name" => name, "ip" => ip} <- rows,
        is_binary(name) and is_binary(ip),
        into: %{},
        do: {name, ip}
  end

  @doc "MAC addresses of a guest configuration's network devices, in `netN` order."
  @spec mac_addresses(map()) :: [String.t()]
  def mac_addresses(config) when is_map(config) do
    config
    |> Enum.filter(fn {key, value} ->
      Regex.match?(@network_device_key, key) and is_binary(value)
    end)
    |> Enum.sort_by(fn {"net" <> index, _value} -> String.to_integer(index) end)
    |> Enum.flat_map(fn {_key, value} -> network_device_mac(value) end)
    |> Enum.uniq()
  end

  def mac_addresses(_config), do: []

  @doc """
  Builds the workload of a guest row, with the MAC addresses of its configuration and
  the IP address of its node.
  """
  @spec workload(map(), [String.t()], %{String.t() => String.t()}) :: Workload.t()
  def workload(row, macs, ip_by_node) do
    node = row["node"]

    %Workload{
      provider: @provider,
      source: Map.fetch!(@source_by_type, row["type"]),
      kind: Map.fetch!(@kind_by_type, row["type"]),
      name: row["name"] || "#{row["vmid"]}",
      reference: row["id"] || "#{row["type"]}/#{row["vmid"]}",
      status: row["status"],
      macs: macs,
      host: %HostReference{name: node, ips: List.wrap(Map.get(ip_by_node, node))}
    }
  end

  # Any `key=value` of the device whose value is a MAC address (`virtio=`, `macaddr=`,
  # `hwaddr=`…).
  defp network_device_mac(value) do
    value
    |> String.split(",")
    |> Enum.find_value([], fn part ->
      with [_key, candidate] <- String.split(part, "=", parts: 2),
           {:ok, mac} <- MacAddress.normalize(candidate) do
        [mac]
      else
        _other -> nil
      end
    end)
  end
end
