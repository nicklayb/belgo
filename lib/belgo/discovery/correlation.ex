defmodule Belgo.Discovery.Correlation do
  @moduledoc """
  Confronts provider observations with the inventory. Pure functions only.

  Device observations sharing a MAC or an IP address are merged into one
  `DiscoveredDevice` (an OPNsense reservation and an AdGuard rewrite of the same IP
  describe the same machine). Each discovered device is then:

    * ignored, when one of its MAC addresses is in the denylist
    * claimed, when one of its MAC or IP addresses, or one of its DNS names, belongs
      to an inventory device or virtual IP; differences become divergences, reconciled
      manually. The MAC address reported with a virtual IP (clients seen by AdGuard
      Home or Omada) is the one of whichever machine answers for it right now: it is
      dropped, so the virtual IP never merges with that machine.
    * unknown otherwise, suggested for claiming; unknown devices whose addresses are
      all outside the DHCP range of their network (static or reserved addresses) are
      listed apart as out of DHCP. A network without range in the inventory uses the
      range reported by a provider (OPNsense Kea pool), without writing it.

  Loopback addresses (`127.0.0.1`, `::1`, reported by AdGuard Home for its own
  queries) never describe a machine of the network: they are dropped from device
  observations, and observations left without MAC, IP nor identity are ignored.

  Location observations (Home Assistant floors and areas) are handled by
  `Belgo.Discovery.Locations`. DNS names resolving to an inventory address without
  belonging to Belgo are `dns_names` (`Belgo.Discovery.DnsNames`), to claim.
  """

  alias Belgo.Discovery.DnsNames
  alias Belgo.Discovery.DnsNames.DiscoveredDnsName
  alias Belgo.Discovery.Locations
  alias Belgo.Discovery.Locations.DiscoveredLocation
  alias Belgo.Discovery.Observation
  alias Belgo.Discovery.Uplink
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Identifier
  alias Belgo.Inventory.Network
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.VirtualIp
  alias Belgo.Network.Cidr
  alias Belgo.Network.IpAddress
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.DesiredState.DnsRecord

  defmodule DiscoveredDevice do
    @moduledoc "Observations describing one machine unknown to the inventory."
    @enforce_keys [:id, :observations]
    defstruct [:id, :hostname, :description, :role, observations: [], macs: [], ips: []]

    @type t :: %__MODULE__{
            id: String.t(),
            hostname: String.t() | nil,
            description: String.t() | nil,
            role: :gateway | :switch | :access_point | nil,
            observations: [Observation.t()],
            macs: [String.t()],
            ips: [String.t()]
          }
  end

  defmodule DiscoveredNetwork do
    @moduledoc "A network reported by a provider and missing from the inventory."
    @enforce_keys [:id, :cidr, :observations]
    defstruct [
      :id,
      :cidr,
      :gateway,
      :domain,
      :dhcp_start,
      :dhcp_end,
      :description,
      observations: []
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            cidr: String.t(),
            gateway: String.t() | nil,
            domain: String.t() | nil,
            dhcp_start: String.t() | nil,
            dhcp_end: String.t() | nil,
            description: String.t() | nil,
            observations: [Observation.t()]
          }
  end

  defmodule Divergence do
    @moduledoc "A difference between a provider and an inventory record."
    @enforce_keys [:collection, :id, :provider, :message]
    defstruct [:collection, :id, :provider, :message]

    @type t :: %__MODULE__{
            collection: Snapshot.collection(),
            id: String.t(),
            provider: atom(),
            message: String.t()
          }
  end

  defmodule Conflict do
    @moduledoc "A record duplicated on a provider, e.g. two Unbound host overrides for one name."
    @enforce_keys [:provider, :name, :message]
    defstruct [:provider, :name, :message, :owner_id, entries: []]

    @type t :: %__MODULE__{
            provider: atom(),
            name: String.t(),
            message: String.t(),
            owner_id: String.t() | nil,
            entries: [Observation.t()]
          }
  end

  defstruct unknown_devices: [],
            out_of_dhcp_devices: [],
            conflicts: [],
            dhcp_ranges: %{},
            uplinks: %{},
            ignored_devices: [],
            new_networks: [],
            new_locations: [],
            dns_names: [],
            divergences: []

  @type t :: %__MODULE__{
          unknown_devices: [DiscoveredDevice.t()],
          out_of_dhcp_devices: [DiscoveredDevice.t()],
          conflicts: [Conflict.t()],
          dhcp_ranges: %{String.t() => dhcp_range()},
          uplinks: %{String.t() => Uplink.t()},
          ignored_devices: [DiscoveredDevice.t()],
          new_networks: [DiscoveredNetwork.t()],
          new_locations: [DiscoveredLocation.t()],
          dns_names: [DiscoveredDnsName.t()],
          divergences: [Divergence.t()]
        }

  @typedoc "Effective DHCP range of a network and where it comes from."
  @type dhcp_range :: %{start: String.t(), end: String.t(), source: :inventory | atom()}

  @doc "Correlates observations of every provider with the snapshot."
  @spec build(Snapshot.t(), [Observation.t()]) :: t()
  def build(%Snapshot{} = snapshot, observations) do
    observations_by_kind = Enum.group_by(observations, & &1.kind)
    context = device_context(snapshot)

    device_observations =
      observations_by_kind
      |> Map.get(:device, [])
      |> Enum.flat_map(&drop_loopback_address/1)
      |> Enum.map(&release_floating_mac(&1, context))

    network_observations = Map.get(observations_by_kind, :network, [])

    {new_networks, network_divergences} = correlate_networks(snapshot, network_observations)

    {new_locations, location_divergences} =
      Locations.correlate(snapshot, Map.get(observations_by_kind, :location, []))

    conflicts = Enum.map(conflicts(device_observations), &own_conflict(&1, context))

    {ignored, claimed, unknown} =
      device_observations
      |> group()
      |> Enum.reduce({[], [], []}, fn discovered, {ignored, claimed, unknown} ->
        case classify(discovered, context) do
          :ignored -> {[discovered | ignored], claimed, unknown}
          {:claimed, devices} -> {ignored, [{discovered, devices} | claimed], unknown}
          :unknown -> {ignored, claimed, [discovered | unknown]}
        end
      end)

    dhcp_ranges = dhcp_ranges(snapshot.networks, network_observations)
    networks = Enum.map(snapshot.networks, &with_dhcp_range(&1, dhcp_ranges))
    {out_of_dhcp, in_dhcp_or_unknown} = Enum.split_with(unknown, &out_of_dhcp?(&1, networks))

    %__MODULE__{
      unknown_devices: sort_devices(in_dhcp_or_unknown),
      out_of_dhcp_devices: sort_devices(out_of_dhcp),
      conflicts: conflicts,
      dhcp_ranges: dhcp_ranges,
      uplinks: uplinks(device_observations, context),
      ignored_devices: sort_devices(ignored),
      new_networks: new_networks,
      new_locations: new_locations,
      dns_names:
        DnsNames.build(
          snapshot,
          device_observations,
          context.desired_state,
          Enum.map(conflicts, & &1.name)
        ),
      divergences:
        claimed
        |> Enum.flat_map(fn {discovered, devices} ->
          device_divergences(discovered, devices, context)
        end)
        |> Kernel.++(network_divergences)
        |> Kernel.++(location_divergences)
        |> Kernel.++(conflict_divergences(conflicts))
        |> Enum.uniq()
        |> Enum.sort_by(&{&1.collection, &1.id, &1.message})
    }
  end

  @doc "Finds an unknown or ignored discovered device by identifier."
  @spec fetch_device(t(), String.t()) :: {:ok, DiscoveredDevice.t()} | {:error, :not_found}
  def fetch_device(%__MODULE__{} = correlation, id) do
    candidates =
      correlation.unknown_devices ++
        correlation.out_of_dhcp_devices ++ correlation.ignored_devices

    case Enum.find(candidates, &(&1.id == id)) do
      nil -> {:error, :not_found}
      discovered -> {:ok, discovered}
    end
  end

  @doc "Finds an unowned DNS name by identifier."
  @spec fetch_dns_name(t(), String.t()) :: {:ok, DiscoveredDnsName.t()} | {:error, :not_found}
  def fetch_dns_name(%__MODULE__{} = correlation, id) do
    case Enum.find(correlation.dns_names, &(&1.id == id)) do
      nil -> {:error, :not_found}
      discovered -> {:ok, discovered}
    end
  end

  @doc "Lists the IP addresses of the unknown devices (out of DHCP included), to ping them."
  @spec discovered_addresses(t()) :: [String.t()]
  def discovered_addresses(%__MODULE__{} = correlation) do
    (correlation.unknown_devices ++ correlation.out_of_dhcp_devices)
    |> Enum.flat_map(& &1.ips)
    |> Enum.uniq()
  end

  @doc "Finds a new network by identifier."
  @spec fetch_network(t(), String.t()) :: {:ok, DiscoveredNetwork.t()} | {:error, :not_found}
  def fetch_network(%__MODULE__{} = correlation, id) do
    case Enum.find(correlation.new_networks, &(&1.id == id)) do
      nil -> {:error, :not_found}
      discovered -> {:ok, discovered}
    end
  end

  @doc "Finds a new location by identifier."
  @spec fetch_location(t(), String.t()) :: {:ok, DiscoveredLocation.t()} | {:error, :not_found}
  def fetch_location(%__MODULE__{} = correlation, id) do
    case Enum.find(correlation.new_locations, &(&1.id == id)) do
      nil -> {:error, :not_found}
      discovered -> {:ok, discovered}
    end
  end

  @doc "Lists the conflicts not attached to an inventory record (shown on their own)."
  @spec unowned_conflicts(t()) :: [Conflict.t()]
  def unowned_conflicts(%__MODULE__{conflicts: conflicts}),
    do: Enum.filter(conflicts, &is_nil(&1.owner_id))

  @doc "Returns where a device is connected right now, if a provider reports it."
  @spec uplink(t(), String.t()) :: Uplink.t() | nil
  def uplink(%__MODULE__{uplinks: uplinks}, device_id), do: Map.get(uplinks, device_id)

  @doc "Lists the divergences of one record."
  @spec divergences_for(t(), Snapshot.collection(), String.t()) :: [Divergence.t()]
  def divergences_for(%__MODULE__{divergences: divergences}, collection, id) do
    Enum.filter(divergences, &(&1.collection == collection and &1.id == id))
  end

  defp group(observations) do
    observations
    |> Enum.filter(&(&1.mac || &1.ip || &1.identity))
    |> Enum.reduce([], fn observation, groups ->
      keys = keys(observation)
      {related, unrelated} = Enum.split_with(groups, &(not MapSet.disjoint?(&1.keys, keys)))

      merged = %{
        keys: Enum.reduce(related, keys, &MapSet.union(&1.keys, &2)),
        observations: Enum.flat_map(related, & &1.observations) ++ [observation]
      }

      [merged | unrelated]
    end)
    |> Enum.map(&discovered_device(&1.observations))
  end

  defp keys(observation) do
    [{:mac, observation.mac}, {:ip, observation.ip}, {:identity, observation.identity}]
    |> Enum.reject(fn {_type, value} -> is_nil(value) end)
    |> MapSet.new()
  end

  defp discovered_device(observations) do
    observations = Enum.sort_by(observations, &{&1.provider, &1.source, &1.reference || ""})

    macs =
      observations
      |> Enum.map(& &1.mac)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    ips =
      observations
      |> Enum.map(& &1.ip)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort_by(&IpAddress.sort_key/1)

    %DiscoveredDevice{
      id: identifier(macs, ips, observations),
      hostname: first_present(observations, :hostname),
      description: first_present(observations, :description),
      role: first_present(observations, :role),
      observations: observations,
      macs: macs,
      ips: ips
    }
  end

  defp identifier([mac | _macs], _ips, _observations), do: "mac-" <> Identifier.slugify(mac)
  defp identifier([], [ip | _ips], _observations), do: "ip-" <> Identifier.slugify(ip)

  defp identifier([], [], observations),
    do: "id-" <> Identifier.slugify(Enum.find_value(observations, & &1.identity))

  defp first_present(observations, field) do
    observations
    |> Enum.sort_by(&source_priority/1)
    |> Enum.find_value(&Map.fetch!(&1, field))
  end

  defp source_priority(%Observation{source: :kea_reservation}), do: 0
  defp source_priority(_observation), do: 1

  defp device_context(snapshot) do
    desired_state = DesiredState.build(snapshot)

    interfaces =
      for device <- snapshot.devices, interface <- device.interfaces, do: {device, interface}

    %{
      denied_macs: MapSet.new(snapshot.denylist, & &1.id),
      interface_by_mac:
        for(
          {device, %{mac: mac} = interface} <- interfaces,
          mac != nil,
          into: %{},
          do: {mac, {device, interface}}
        ),
      device_by_ip:
        for({device, %{ip: ip}} <- interfaces, ip != nil, into: %{}, do: {ip, device}),
      device_by_dns_name: device_by_dns_name(snapshot, desired_state),
      owner_by_dns_name: owner_by_dns_name(snapshot, desired_state),
      virtual_ip_by_ip: Map.new(snapshot.virtual_ips, &{&1.ip, &1}),
      desired_state: desired_state
    }
  end

  defp device_by_dns_name(snapshot, desired_state) do
    device_by_id = Snapshot.index(snapshot, :devices)

    for %DnsRecord{device_id: device_id, virtual_ip_id: nil} = record <-
          desired_state.dns_records,
        into: %{},
        do: {record.name, Map.fetch!(device_by_id, device_id)}
  end

  # Devices and virtual IPs, by the DNS names they own.
  defp owner_by_dns_name(snapshot, desired_state) do
    record_by_owner =
      for collection <- [:devices, :virtual_ips],
          record <- Map.fetch!(snapshot, collection),
          into: %{},
          do: {{collection, record.id}, record}

    Map.new(desired_state.dns_records, fn record ->
      {record.name, Map.fetch!(record_by_owner, DnsRecord.owner(record))}
    end)
  end

  @floating_mac_sources [:adguard_client, :adguard_auto_client, :omada_client]

  defp drop_loopback_address(%Observation{ip: ip} = observation) do
    if IpAddress.loopback?(ip) do
      observation = %Observation{observation | ip: nil}
      if observation.mac || observation.identity, do: [observation], else: []
    else
      [observation]
    end
  end

  defp release_floating_mac(%Observation{source: source, ip: ip} = observation, context)
       when source in @floating_mac_sources and is_map_key(context.virtual_ip_by_ip, ip),
       do: %{observation | mac: nil, uplink_mac: nil}

  defp release_floating_mac(observation, _context), do: observation

  defp classify(discovered, context) do
    devices =
      Enum.map(
        discovered.macs,
        &(context.interface_by_mac
          |> Map.get(&1)
          |> device_of())
      ) ++
        Enum.map(discovered.ips, &Map.get(context.device_by_ip, &1)) ++
        Enum.map(discovered.ips, &Map.get(context.virtual_ip_by_ip, &1)) ++
        named_devices(discovered, context)

    cond do
      Enum.any?(discovered.macs, &MapSet.member?(context.denied_macs, &1)) ->
        :ignored

      Enum.any?(devices) ->
        {:claimed,
         devices
         |> Enum.reject(&is_nil/1)
         |> Enum.uniq_by(&{&1.__struct__, &1.id})}

      true ->
        :unknown
    end
  end

  defp named_devices(discovered, context) do
    for observation <- discovered.observations, Observation.dns_record?(observation) do
      Map.get(context.owner_by_dns_name, Observation.fqdn(observation))
    end
  end

  defp device_of(nil), do: nil
  defp device_of({device, _interface}), do: device

  defp device_divergences(discovered, devices, context) do
    Enum.flat_map(discovered.observations, &observation_divergences(&1, devices, context))
  end

  defp observation_divergences(
         %Observation{source: :kea_reservation} = observation,
         devices,
         context
       ) do
    case Map.fetch(context.interface_by_mac, observation.mac) do
      {:ok, {device, interface}} ->
        reservation_divergences(observation, device, interface)

      :error ->
        message =
          "reservation of #{observation.ip} is for MAC #{observation.mac}, unknown to Belgo"

        context.device_by_ip
        |> Map.get(observation.ip)
        |> List.wrap()
        |> fallback(devices)
        |> Enum.map(&divergence(&1, observation, message))
    end
  end

  defp observation_divergences(
         %Observation{} = observation,
         devices,
         context
       )
       when observation.source in [:unbound_host_override, :adguard_rewrite] do
    name = Observation.fqdn(observation)
    records = Enum.filter(context.desired_state.dns_records, &(&1.name == name))

    cond do
      records == [] ->
        Enum.map(
          devices,
          &divergence(&1, observation, "#{name} resolves to #{observation.ip}, unknown to Belgo")
        )

      Enum.any?(records, &(&1.address == observation.ip)) ->
        []

      true ->
        expected = Enum.map_join(records, ", ", & &1.address)

        Enum.map(
          devices,
          &divergence(
            &1,
            observation,
            "#{name} resolves to #{observation.ip}, Belgo expects #{expected}"
          )
        )
    end
  end

  defp observation_divergences(
         %Observation{} = observation,
         _devices,
         context
       )
       when observation.source in [:adguard_client, :omada_client] do
    owner =
      case Map.fetch(context.interface_by_mac, observation.mac) do
        {:ok, {device, _interface}} -> device
        :error -> Map.get(context.device_by_ip, observation.ip)
      end

    name_divergences =
      if owner && observation.description != owner.name,
        do: [
          divergence(
            owner,
            observation,
            "client name is #{observation.description}, Belgo has #{owner.name}"
          )
        ],
        else: []

    name_divergences ++ stale_address_divergences(observation, context)
  end

  defp observation_divergences(%Observation{source: :kea_lease} = observation, _devices, context),
    do: stale_address_divergences(observation, context)

  defp observation_divergences(_observation, _devices, _context), do: []

  @live_address_sources [:omada_client, :kea_lease]

  # A client seen right now (Omada client, active Kea lease) at another address than
  # the one Belgo assigns to its interface: the device still holds its old lease, a
  # restart (or lease renewal) makes it take the new one. Dynamic interfaces have no
  # assigned address. An observation in another subnet (a lease left on a former
  # VLAN) says nothing about this interface.
  defp stale_address_divergences(%Observation{source: source} = observation, context)
       when source in @live_address_sources and is_binary(observation.ip) do
    case Map.fetch(context.interface_by_mac, observation.mac) do
      {:ok, {device, %{assignment: assignment, ip: ip} = interface}}
      when assignment in [:reserved, :static] and is_binary(ip) and ip != observation.ip ->
        stale_address_divergence(observation, device, interface)

      _same_or_unknown ->
        []
    end
  end

  defp stale_address_divergences(_observation, _context), do: []

  defp stale_address_divergence(observation, device, %{ip: ip} = interface) do
    if same_subnet?(observation.cidr, ip) do
      [
        divergence(
          device,
          observation,
          "#{Device.interface_label(device, interface)} is seen at #{observation.ip}, Belgo assigns #{ip}: restart it (or renew its DHCP lease) to take the new address"
        )
      ]
    else
      []
    end
  end

  defp same_subnet?(nil, _ip), do: true

  defp same_subnet?(cidr, ip) do
    with {:ok, parsed_cidr} <- Cidr.parse(cidr),
         {:ok, address} <- IpAddress.parse(ip) do
      Cidr.contains?(parsed_cidr, address)
    else
      _invalid -> true
    end
  end

  defp fallback([], devices), do: devices
  defp fallback(owners, _devices), do: owners

  defp reservation_divergences(observation, device, interface) do
    [
      {observation.ip != interface.ip,
       "reservation of #{observation.mac} uses #{observation.ip}, Belgo has #{interface.ip || "no address"}"},
      {observation.hostname != nil and observation.hostname != Device.hostname(device),
       "reservation hostname is #{observation.hostname}, Belgo has #{Device.hostname(device)}"},
      {observation.description != Device.interface_label(device, interface),
       "reservation description is #{observation.description || "empty"}, Belgo has #{Device.interface_label(device, interface)}"},
      {interface.assignment != :reserved,
       "#{observation.mac} has a reservation, Belgo does not expect one (#{interface.assignment})"}
    ]
    |> Enum.filter(fn {different?, _message} -> different? end)
    |> Enum.map(fn {_different?, message} -> divergence(device, observation, message) end)
  end

  defp divergence(record, observation, message) do
    %Divergence{
      collection: if(match?(%VirtualIp{}, record), do: :virtual_ips, else: :devices),
      id: record.id,
      provider: observation.provider,
      message: message
    }
  end

  defp correlate_networks(snapshot, observations) do
    network_by_cidr = Map.new(snapshot.networks, &{&1.cidr, &1})

    observations
    |> Enum.group_by(& &1.cidr)
    |> Enum.sort_by(fn {cidr, _observations} -> cidr_sort_key(cidr) end)
    |> Enum.reduce({[], []}, fn {cidr, cidr_observations}, {new_networks, divergences} ->
      case Map.fetch(network_by_cidr, cidr) do
        {:ok, network} ->
          {new_networks,
           divergences ++ Enum.flat_map(cidr_observations, &network_divergences(network, &1))}

        :error ->
          {new_networks ++ [discovered_network(cidr, cidr_observations)], divergences}
      end
    end)
  end

  defp cidr_sort_key(cidr) do
    cidr
    |> String.split("/")
    |> List.first()
    |> IpAddress.sort_key()
  end

  defp discovered_network(cidr, observations) do
    %DiscoveredNetwork{
      id: Identifier.slugify(cidr),
      cidr: cidr,
      gateway: first_present(observations, :gateway),
      domain: first_present(observations, :domain),
      dhcp_start: first_present(observations, :dhcp_start),
      dhcp_end: first_present(observations, :dhcp_end),
      description: first_present(observations, :description),
      observations: observations
    }
  end

  defp network_divergences(network, observation) do
    [
      {:gateway, network.gateway, observation.gateway},
      {:domain, network.domain, observation.domain},
      {:dhcp_range, dhcp_range(network), dhcp_range(observation)}
    ]
    |> Enum.filter(fn
      {:dhcp_range, nil, _reported} -> false
      {_field, expected, reported} -> reported != nil and reported != expected
    end)
    |> Enum.map(fn {field, expected, reported} ->
      field = String.replace(Atom.to_string(field), "_", " ")

      %Divergence{
        collection: :networks,
        id: network.id,
        provider: observation.provider,
        message: "#{field} is #{reported}, Belgo has #{expected || "none"}"
      }
    end)
  end

  defp conflicts(device_observations) do
    device_observations
    |> Enum.filter(&(&1.source == :unbound_host_override))
    |> Enum.group_by(&Observation.fqdn/1)
    |> Enum.filter(fn {_name, entries} -> length(entries) > 1 end)
    |> Enum.sort_by(fn {name, _entries} -> name end)
    |> Enum.map(fn {name, entries} ->
      %Conflict{
        provider: hd(entries).provider,
        name: name,
        entries: entries,
        message:
          "#{name} has #{length(entries)} Unbound host overrides: #{Enum.map_join(entries, ", ", &describe_entry/1)}"
      }
    end)
  end

  defp describe_entry(%Observation{ip: ip, description: nil}), do: ip

  defp describe_entry(%Observation{ip: ip, description: description}),
    do: "#{ip} (#{description})"

  defp own_conflict(conflict, context) do
    case Map.fetch(context.device_by_dns_name, conflict.name) do
      {:ok, device} -> %{conflict | owner_id: device.id}
      :error -> conflict
    end
  end

  defp conflict_divergences(conflicts) do
    for %Conflict{owner_id: owner_id} = conflict <- conflicts, owner_id != nil do
      %Divergence{
        collection: :devices,
        id: owner_id,
        provider: conflict.provider,
        message: conflict.message
      }
    end
  end

  defp uplinks(device_observations, context) do
    device_observations
    |> Enum.filter(&(&1.mac && &1.uplink_mac))
    |> Enum.sort_by(&{&1.wireless == true, &1.provider, &1.mac})
    |> Enum.reduce(%{}, fn observation, uplinks ->
      with {:ok, {device, _interface}} <- Map.fetch(context.interface_by_mac, observation.mac),
           false <- Map.has_key?(uplinks, device.id) do
        Map.put(uplinks, device.id, uplink(device, observation, context))
      else
        _ -> uplinks
      end
    end)
  end

  defp uplink(device, observation, context) do
    switch =
      context.interface_by_mac
      |> Map.get(observation.uplink_mac)
      |> device_of()

    %Uplink{
      device_id: device.id,
      provider: observation.provider,
      switch_id: switch && switch.id,
      switch_name: (switch && switch.name) || observation.uplink_name,
      port: observation.uplink_port,
      ssid: observation.ssid,
      locked_to_ap: observation.locked_to_ap,
      wireless?: observation.wireless == true
    }
  end

  defp dhcp_ranges(networks, network_observations) do
    for network <- networks,
        range = inventory_range(network) || observed_range(network, network_observations),
        range != nil,
        into: %{},
        do: {network.id, range}
  end

  defp inventory_range(network) do
    if Network.dhcp_range?(network),
      do: %{start: network.dhcp_start, end: network.dhcp_end, source: :inventory}
  end

  defp observed_range(network, network_observations) do
    Enum.find_value(network_observations, fn observation ->
      if (observation.cidr == network.cidr and observation.dhcp_start) && observation.dhcp_end,
        do: %{
          start: observation.dhcp_start,
          end: observation.dhcp_end,
          source: observation.provider
        }
    end)
  end

  defp with_dhcp_range(network, dhcp_ranges) do
    case Map.fetch(dhcp_ranges, network.id) do
      {:ok, range} -> %{network | dhcp_start: range.start, dhcp_end: range.end}
      :error -> network
    end
  end

  defp dhcp_range(%{dhcp_start: dhcp_start, dhcp_end: dhcp_end})
       when is_binary(dhcp_start) and is_binary(dhcp_end),
       do: "#{dhcp_start}–#{dhcp_end}"

  defp dhcp_range(_record), do: nil

  defp sort_devices(devices), do: Enum.sort_by(devices, &{&1.hostname || "~", &1.id})

  defp out_of_dhcp?(%DiscoveredDevice{ips: []}, _networks), do: false

  defp out_of_dhcp?(%DiscoveredDevice{ips: ips}, networks) do
    Enum.all?(ips, fn ip ->
      case Enum.find(networks, &Network.contains?(&1, ip)) do
        nil -> false
        network -> Network.dhcp_range?(network) and not Network.in_dhcp_range?(network, ip)
      end
    end)
  end
end
