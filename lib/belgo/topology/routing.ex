defmodule Belgo.Topology.Routing do
  @moduledoc """
  The network path of the homelab: which switch or access point every device is
  connected to, up to the gateway.

  A device's link is the live uplink reported by a provider (Omada) when there is
  one, else the switch its first interface is plugged into in the inventory. Network
  nodes (devices with a `network_role`) form the tree; other devices are listed as
  the clients of the node they are connected to. Cycles are cut.
  """

  alias Belgo.Discovery.Uplink
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Snapshot

  defmodule Link do
    @moduledoc "Where a device is connected: the switch / AP, its port, and the source of the information."
    @enforce_keys [:device_id, :source]
    defstruct [
      :device_id,
      :source,
      :switch_id,
      :switch_name,
      :port,
      :ssid,
      :locked_to_ap,
      wireless?: false
    ]

    @type t :: %__MODULE__{
            device_id: String.t(),
            source: :inventory | atom(),
            switch_id: String.t() | nil,
            switch_name: String.t() | nil,
            port: String.t() | nil,
            ssid: String.t() | nil,
            locked_to_ap: boolean() | nil,
            wireless?: boolean()
          }
  end

  defmodule Node do
    @moduledoc """
    A network node with the nodes and the clients connected to it. `used_ports` counts
    the ports taken by wired devices plugged into it (see `Routing.used_ports/1`).
    """
    defstruct [:device, :link, used_ports: 0, children: [], clients: []]

    @type t :: %__MODULE__{
            device: Device.t(),
            link: Link.t() | nil,
            used_ports: non_neg_integer(),
            children: [t()],
            clients: [{Device.t(), Link.t()}]
          }
  end

  defmodule Hop do
    @moduledoc "One step of a network path: a device (or a node unknown to Belgo) and how it is reached."
    defstruct [:device, :name, :link]

    @type t :: %__MODULE__{device: Device.t() | nil, name: String.t(), link: Link.t() | nil}
  end

  @role_order %{gateway: 0, switch: 1, access_point: 2}

  @doc "Computes the link of every connected device from the live uplinks and the inventory."
  @spec links(Snapshot.t(), %{String.t() => Uplink.t()}) :: %{String.t() => Link.t()}
  def links(%Snapshot{} = snapshot, uplinks) do
    device_by_id = Snapshot.index(snapshot, :devices)

    for device <- snapshot.devices,
        link = live_link(Map.get(uplinks, device.id)) || inventory_link(device),
        link != nil,
        into: %{},
        do: {device.id, name_switch(link, device_by_id)}
  end

  defp name_switch(%Link{switch_id: switch_id} = link, device_by_id) when is_binary(switch_id) do
    case Map.fetch(device_by_id, switch_id) do
      {:ok, switch} -> %{link | switch_name: switch.name}
      :error -> link
    end
  end

  defp name_switch(link, _device_by_id), do: link

  @doc "Builds the routing tree, gateways first."
  @spec build(Snapshot.t(), %{String.t() => Link.t()}) :: [Node.t()]
  def build(%Snapshot{} = snapshot, links) do
    device_by_id = Snapshot.index(snapshot, :devices)
    linked_by_switch = Enum.group_by(Map.values(links), & &1.switch_id)

    snapshot.devices
    |> Enum.filter(&(Device.network_node?(&1) and root?(&1, links, device_by_id)))
    |> sort_nodes()
    |> Enum.map(&node(&1, links, linked_by_switch, device_by_id, MapSet.new()))
  end

  @doc "Returns the path from a device up to the last reachable node (the gateway)."
  @spec path(Snapshot.t(), %{String.t() => Link.t()}, String.t()) :: [Hop.t()]
  def path(%Snapshot{} = snapshot, links, device_id) do
    device_by_id = Snapshot.index(snapshot, :devices)

    case Map.fetch(device_by_id, device_id) do
      {:ok, device} -> walk(device, links, device_by_id, MapSet.new([device_id]))
      :error -> []
    end
  end

  defp walk(device, links, device_by_id, visited) do
    link = Map.get(links, device.id)
    hop = %Hop{device: device, name: device.name, link: link}

    cond do
      is_nil(link) ->
        [hop]

      is_nil(link.switch_id) and link.switch_name ->
        [hop, %Hop{name: link.switch_name}]

      is_nil(link.switch_id) or MapSet.member?(visited, link.switch_id) ->
        [hop]

      true ->
        case Map.fetch(device_by_id, link.switch_id) do
          {:ok, switch} ->
            [hop | walk(switch, links, device_by_id, MapSet.put(visited, switch.id))]

          :error ->
            [hop, %Hop{name: link.switch_id}]
        end
    end
  end

  @doc """
  Counts the ports taken on a switch by the links plugged into it: wireless links
  take none, links on the same port share it, a link without port takes one.
  The switch's own uplink is not counted (it may use a dedicated port, like SFP).
  """
  @spec used_ports([Link.t()]) :: non_neg_integer()
  def used_ports(links) do
    {with_port, without_port} =
      links
      |> Enum.reject(& &1.wireless?)
      |> Enum.split_with(&(&1.port not in [nil, ""]))

    length(Enum.uniq_by(with_port, &port_key/1)) + length(without_port)
  end

  defp port_key(%Link{port: port}) do
    port
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp node(device, links, linked_by_switch, device_by_id, visited) do
    visited = MapSet.put(visited, device.id)
    plugged = Map.get(linked_by_switch, device.id, [])

    {nodes, clients} =
      plugged
      |> Enum.reject(&MapSet.member?(visited, &1.device_id))
      |> Enum.map(&{Map.fetch!(device_by_id, &1.device_id), &1})
      |> Enum.split_with(fn {linked, _link} -> Device.network_node?(linked) end)

    %Node{
      device: device,
      link: Map.get(links, device.id),
      used_ports: used_ports(plugged),
      children:
        nodes
        |> Enum.map(fn {linked, _link} -> linked end)
        |> sort_nodes()
        |> Enum.map(&node(&1, links, linked_by_switch, device_by_id, visited)),
      clients: Enum.sort_by(clients, fn {client, _link} -> String.downcase(client.name) end)
    }
  end

  defp root?(device, links, device_by_id) do
    case Map.get(links, device.id) do
      nil ->
        true

      %Link{switch_id: nil} ->
        true

      %Link{switch_id: switch_id} ->
        not Map.has_key?(device_by_id, switch_id) or cyclic?(device.id, links)
    end
  end

  defp cyclic?(device_id, links),
    do: cyclic?(device_id, links, Map.get(links, device_id), MapSet.new())

  defp cyclic?(_origin, _links, nil, _visited), do: false
  defp cyclic?(_origin, _links, %Link{switch_id: nil}, _visited), do: false
  defp cyclic?(origin, _links, %Link{switch_id: origin}, _visited), do: true

  defp cyclic?(origin, links, %Link{switch_id: switch_id}, visited) do
    if MapSet.member?(visited, switch_id),
      do: false,
      else: cyclic?(origin, links, Map.get(links, switch_id), MapSet.put(visited, switch_id))
  end

  defp live_link(nil), do: nil

  defp live_link(%Uplink{} = uplink) do
    %Link{
      device_id: uplink.device_id,
      source: uplink.provider,
      switch_id: uplink.switch_id,
      switch_name: uplink.switch_name,
      port: uplink.port,
      ssid: uplink.ssid,
      locked_to_ap: uplink.locked_to_ap,
      wireless?: uplink.wireless?
    }
  end

  defp inventory_link(device) do
    case Enum.find(device.interfaces, & &1.switch_id) do
      nil ->
        device_uplink(device)

      interface ->
        %Link{
          device_id: device.id,
          source: :inventory,
          switch_id: interface.switch_id,
          port: interface.switch_port
        }
    end
  end

  defp device_uplink(%Device{uplink_id: nil}), do: nil

  defp device_uplink(%Device{} = device),
    do: %Link{
      device_id: device.id,
      source: :inventory,
      switch_id: device.uplink_id,
      port: device.uplink_port
    }

  defp sort_nodes(devices) do
    Enum.sort_by(devices, &{Map.get(@role_order, &1.network_role, 3), String.downcase(&1.name)})
  end
end
