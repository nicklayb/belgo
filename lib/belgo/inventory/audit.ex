defmodule Belgo.Inventory.Audit do
  @moduledoc """
  Cross record consistency checks: dangling references, cycles, address conflicts...

  Single records are validated by their changeset. Checks requiring the whole
  inventory live here so they apply equally to forms and to hand edited files.
  """

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Issue
  alias Belgo.Inventory.Network
  alias Belgo.Inventory.Snapshot
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.DesiredState.DnsRecord

  @doc "Lists every issue of the snapshot, sorted deterministically."
  @spec issues(Snapshot.t()) :: [Issue.t()]
  def issues(%Snapshot{} = snapshot) do
    [
      location_issues(snapshot),
      duplicate_home_assistant_issues(snapshot),
      device_issues(snapshot),
      duplicate_issues(snapshot, :ip, "IP address"),
      duplicate_issues(snapshot, :mac, "MAC address"),
      duplicate_hostname_issues(snapshot),
      dns_name_issues(snapshot),
      virtual_ip_issues(snapshot),
      virtual_ip_address_issues(snapshot)
    ]
    |> Enum.concat()
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.collection, &1.id, &1.field, &1.message})
  end

  @doc "Lists the issues attached to one record."
  @spec issues_for([Issue.t()], Snapshot.collection(), String.t()) :: [Issue.t()]
  def issues_for(issues, collection, id) do
    Enum.filter(issues, &(&1.collection == collection and &1.id == id))
  end

  defp location_issues(snapshot) do
    location_by_id = Snapshot.index(snapshot, :locations)

    parent_of = fn id ->
      location_by_id
      |> Map.get(id, %{})
      |> Map.get(:parent_id)
    end

    Enum.flat_map(snapshot.locations, fn location ->
      cond do
        location.parent_id && not Map.has_key?(location_by_id, location.parent_id) ->
          [unknown(:locations, location.id, :parent_id, "location", location.parent_id)]

        cyclic?(location.id, parent_of) ->
          [Issue.error(:locations, location.id, :parent_id, "creates a cycle of locations")]

        true ->
          []
      end
    end)
  end

  defp duplicate_home_assistant_issues(snapshot) do
    snapshot.locations
    |> Enum.reject(&is_nil(&1.home_assistant_id))
    |> Enum.group_by(& &1.home_assistant_id)
    |> Enum.flat_map(fn
      {_reference, [_single]} ->
        []

      {reference, locations} ->
        Enum.map(locations, fn location ->
          others =
            locations
            |> Enum.reject(&(&1.id == location.id))
            |> Enum.map_join(", ", & &1.name)

          Issue.error(
            :locations,
            location.id,
            :home_assistant_id,
            "Home Assistant #{reference} is also linked to #{others}"
          )
        end)
    end)
  end

  defp device_issues(snapshot) do
    context = %{
      location_by_id: Snapshot.index(snapshot, :locations),
      network_by_id: Snapshot.index(snapshot, :networks),
      device_by_id: Snapshot.index(snapshot, :devices)
    }

    Enum.flat_map(snapshot.devices, fn device ->
      placement_issues(device, context) ++
        uplink_issues(device, context) ++
        Enum.flat_map(device.interfaces, &interface_issues(device, &1, context))
    end)
  end

  defp placement_issues(device, context) do
    case Device.placement(device) do
      {:location, location_id} when not is_map_key(context.location_by_id, location_id) ->
        [unknown(:devices, device.id, :location_id, "location", location_id)]

      {:host, host_id} ->
        host_issues(device, host_id, context)

      _valid ->
        []
    end
  end

  defp uplink_issues(%Device{uplink_id: nil}, _context), do: []

  defp uplink_issues(device, %{device_by_id: device_by_id}) do
    case Map.fetch(device_by_id, device.uplink_id) do
      :error ->
        [unknown(:devices, device.id, :uplink_id, "uplink device", device.uplink_id)]

      {:ok, %Device{kind: :network}} ->
        []

      {:ok, uplink} ->
        [
          Issue.warning(
            :devices,
            device.id,
            :uplink_id,
            "plugged into #{uplink.name}, which is not a network device"
          )
        ]
    end
  end

  defp host_issues(device, host_id, %{device_by_id: device_by_id}) do
    host_of = fn id ->
      device_by_id
      |> Map.get(id, %{})
      |> Map.get(:host_id)
    end

    case Map.fetch(device_by_id, host_id) do
      :error ->
        [unknown(:devices, device.id, :host_id, "host", host_id)]

      {:ok, host} ->
        cond do
          cyclic?(device.id, host_of) ->
            [Issue.error(:devices, device.id, :host_id, "creates a cycle of hosts")]

          not Device.host?(host) ->
            [
              Issue.warning(
                :devices,
                device.id,
                :host_id,
                "host #{host.name} does not declare any platform"
              )
            ]

          true ->
            []
        end
    end
  end

  defp interface_issues(device, interface, context) do
    label = interface_label(interface)

    network_issues(device, interface, label, context) ++
      switch_issues(device, interface, label, context)
  end

  defp network_issues(_device, %{network_id: nil}, _label, _context), do: []

  defp network_issues(device, interface, label, %{network_by_id: network_by_id}) do
    case Map.fetch(network_by_id, interface.network_id) do
      :error ->
        [
          Issue.error(
            :devices,
            device.id,
            :interfaces,
            "#{label}: unknown network #{interface.network_id}"
          )
        ]

      {:ok, network} ->
        if interface.ip && not Network.contains?(network, interface.ip) do
          [
            Issue.error(
              :devices,
              device.id,
              :interfaces,
              "#{label}: #{interface.ip} is outside of #{network.name} (#{network.cidr})"
            )
          ]
        else
          []
        end
    end
  end

  defp switch_issues(_device, %{switch_id: nil}, _label, _context), do: []

  defp switch_issues(device, interface, label, %{device_by_id: device_by_id}) do
    case Map.fetch(device_by_id, interface.switch_id) do
      :error ->
        [
          Issue.error(
            :devices,
            device.id,
            :interfaces,
            "#{label}: unknown switch #{interface.switch_id}"
          )
        ]

      {:ok, %Device{kind: :network}} ->
        []

      {:ok, switch} ->
        [
          Issue.warning(
            :devices,
            device.id,
            :interfaces,
            "#{label}: #{switch.name} is not a network device"
          )
        ]
    end
  end

  defp duplicate_issues(snapshot, field, label) do
    snapshot.devices
    |> Enum.flat_map(fn device ->
      device.interfaces
      |> Enum.map(&Map.fetch!(&1, field))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&{&1, device})
    end)
    |> Enum.group_by(fn {value, _device} -> value end, fn {_value, device} -> device end)
    |> Enum.flat_map(fn {value, devices} -> conflicts(devices, :interfaces, label, value) end)
  end

  defp duplicate_hostname_issues(snapshot) do
    snapshot.devices
    |> Enum.group_by(&Device.hostname/1)
    |> Enum.flat_map(fn {hostname, devices} ->
      conflicts(devices, :hostname, "hostname", hostname)
    end)
  end

  defp dns_name_issues(snapshot) do
    name_by_owner = owner_names(snapshot)

    snapshot
    |> DesiredState.build()
    |> Map.fetch!(:dns_records)
    |> Enum.group_by(& &1.name)
    |> Enum.flat_map(fn {name, records} -> dns_name_conflicts(name, records, name_by_owner) end)
  end

  defp owner_names(snapshot) do
    for collection <- [:devices, :virtual_ips],
        record <- Map.fetch!(snapshot, collection),
        into: %{},
        do: {{collection, record.id}, record.name}
  end

  defp dns_name_conflicts(name, records, name_by_owner) do
    owners =
      records
      |> Enum.map(&DnsRecord.owner/1)
      |> Enum.uniq()

    for {collection, id} = owner <- owners, length(owners) > 1 do
      others =
        owners
        |> Enum.reject(&(&1 == owner))
        |> Enum.map_join(", ", &Map.fetch!(name_by_owner, &1))

      Issue.error(
        collection,
        id,
        dns_names_field(collection),
        "DNS name #{name} is also used by #{others}"
      )
    end
  end

  defp dns_names_field(:devices), do: :interfaces
  defp dns_names_field(:virtual_ips), do: :dns_names

  defp virtual_ip_issues(snapshot) do
    network_by_id = Snapshot.index(snapshot, :networks)
    device_by_id = Snapshot.index(snapshot, :devices)

    Enum.flat_map(snapshot.virtual_ips, fn virtual_ip ->
      virtual_ip_network_issues(virtual_ip, network_by_id, snapshot.networks) ++
        virtual_ip_owner_issues(virtual_ip, device_by_id)
    end)
  end

  defp virtual_ip_network_issues(%{network_id: nil} = virtual_ip, _network_by_id, networks) do
    case Enum.find(networks, &Network.contains?(&1, virtual_ip.ip)) do
      nil -> []
      network -> dhcp_range_issues(virtual_ip, network)
    end
  end

  defp virtual_ip_network_issues(virtual_ip, network_by_id, _networks) do
    case Map.fetch(network_by_id, virtual_ip.network_id) do
      :error ->
        [unknown(:virtual_ips, virtual_ip.id, :network_id, "network", virtual_ip.network_id)]

      {:ok, network} ->
        if Network.contains?(network, virtual_ip.ip),
          do: dhcp_range_issues(virtual_ip, network),
          else: [
            Issue.error(
              :virtual_ips,
              virtual_ip.id,
              :ip,
              "#{virtual_ip.ip} is outside of #{network.name} (#{network.cidr})"
            )
          ]
    end
  end

  defp dhcp_range_issues(virtual_ip, network) do
    if Network.in_dhcp_range?(network, virtual_ip.ip),
      do: [
        Issue.warning(
          :virtual_ips,
          virtual_ip.id,
          :ip,
          "#{virtual_ip.ip} is in the DHCP range of #{network.name}: DHCP may lease it to a device"
        )
      ],
      else: []
  end

  defp virtual_ip_owner_issues(%{owner_id: nil}, _device_by_id), do: []

  defp virtual_ip_owner_issues(virtual_ip, device_by_id) do
    if Map.has_key?(device_by_id, virtual_ip.owner_id),
      do: [],
      else: [unknown(:virtual_ips, virtual_ip.id, :owner_id, "device", virtual_ip.owner_id)]
  end

  # A virtual IP address must not be an interface address nor another virtual IP's;
  # the issue goes to every record using it, so each form shows it.
  defp virtual_ip_address_issues(snapshot) do
    users =
      Enum.map(snapshot.virtual_ips, &{&1.ip, {:virtual_ips, &1.id, :ip, &1.name}}) ++
        for device <- snapshot.devices,
            %{ip: ip} <- device.interfaces,
            ip != nil,
            do: {ip, {:devices, device.id, :interfaces, device.name}}

    users
    |> Enum.group_by(fn {ip, _user} -> ip end, fn {_ip, user} -> user end)
    |> Enum.flat_map(fn {ip, ip_users} -> virtual_ip_conflicts(ip, Enum.uniq(ip_users)) end)
  end

  defp virtual_ip_conflicts(ip, users) do
    if Enum.any?(users, &match?({:virtual_ips, _id, _field, _name}, &1)) and length(users) > 1,
      do: Enum.map(users, &address_conflict(&1, users, ip)),
      else: []
  end

  defp address_conflict({collection, id, field, _name} = user, users, ip) do
    others =
      users
      |> Enum.reject(&(&1 == user))
      |> Enum.map_join(", ", fn {_collection, _id, _field, name} -> name end)

    Issue.error(collection, id, field, "IP address #{ip} is also used by #{others}")
  end

  defp conflicts([_single], _field, _label, _value), do: []

  defp conflicts(devices, field, label, value) do
    Enum.map(devices, fn device ->
      others =
        devices
        |> Enum.reject(&(&1.id == device.id))
        |> Enum.map_join(", ", & &1.name)

      message =
        if others == "",
          do: "#{label} #{value} is used more than once",
          else: "#{label} #{value} is also used by #{others}"

      Issue.error(:devices, device.id, field, message)
    end)
  end

  defp unknown(collection, id, field, label, reference) do
    Issue.error(collection, id, field, "unknown #{label} #{reference}")
  end

  defp interface_label(%{name: name}) when is_binary(name), do: "interface #{name}"
  defp interface_label(%{mac: mac}) when is_binary(mac), do: "interface #{mac}"
  defp interface_label(_interface), do: "interface"

  defp cyclic?(origin, parent_of), do: walk(parent_of.(origin), origin, parent_of, MapSet.new())

  defp walk(nil, _origin, _parent_of, _visited), do: false
  defp walk(origin, origin, _parent_of, _visited), do: true

  defp walk(id, origin, parent_of, visited) do
    if MapSet.member?(visited, id),
      do: false,
      else: walk(parent_of.(id), origin, parent_of, MapSet.put(visited, id))
  end
end
