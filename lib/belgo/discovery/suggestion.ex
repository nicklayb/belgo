defmodule Belgo.Discovery.Suggestion do
  @moduledoc "Turns discovered records into form params, ready to be claimed."

  alias Belgo.Discovery.Correlation.DiscoveredDevice
  alias Belgo.Discovery.Correlation.DiscoveredNetwork
  alias Belgo.Discovery.Locations.DiscoveredLocation
  alias Belgo.Discovery.Observation
  alias Belgo.Inventory.Interface
  alias Belgo.Inventory.Location
  alias Belgo.Inventory.Network
  alias Belgo.Inventory.Snapshot

  @root_location_kinds [:site, :building]

  @doc "Device params: hostname, notes, DNS aliases and one interface per MAC address."
  @spec device_params(DiscoveredDevice.t(), Snapshot.t()) :: map()
  def device_params(%DiscoveredDevice{} = discovered, %Snapshot{} = snapshot) do
    name = discovered.hostname || discovered.description || discovered.id

    params = %{
      "name" => name,
      "hostname" => discovered.hostname,
      "notes" => discovered.description,
      "placement" => "unplaced",
      "interfaces" => interfaces(discovered, snapshot)
    }

    Map.merge(params, network_params_of(discovered))
  end

  @doc "Interface params (a list) of a discovered device, as added to an existing device."
  @spec interface_params(DiscoveredDevice.t(), Snapshot.t()) :: [map()]
  def interface_params(%DiscoveredDevice{} = discovered, %Snapshot{} = snapshot) do
    discovered
    |> interfaces(snapshot)
    |> Enum.sort_by(fn {position, _interface} -> String.to_integer(position) end)
    |> Enum.map(fn {_position, interface} -> interface end)
  end

  @doc """
  Virtual IP params from a discovered address (a load balancer address seen with DNS
  names): its first address, its network and the DNS names pointing to it.
  """
  @spec virtual_ip_params(DiscoveredDevice.t(), Snapshot.t()) :: map()
  def virtual_ip_params(%DiscoveredDevice{ips: [ip | _ips]} = discovered, %Snapshot{} = snapshot) do
    %{
      "name" => discovered.hostname || discovered.description || ip,
      "ip" => ip,
      "network_id" => network_id(snapshot, ip),
      "dns_names" => dns_names(discovered, ip, snapshot)
    }
  end

  def virtual_ip_params(%DiscoveredDevice{} = discovered, _snapshot),
    do: %{"name" => discovered.hostname || discovered.description}

  @doc "Network params from a discovered network."
  @spec network_params(DiscoveredNetwork.t()) :: map()
  def network_params(%DiscoveredNetwork{} = discovered) do
    %{
      "name" => discovered.description || discovered.cidr,
      "cidr" => discovered.cidr,
      "gateway" => discovered.gateway,
      "domain" => discovered.domain,
      "dhcp_start" => discovered.dhcp_start,
      "dhcp_end" => discovered.dhcp_end
    }
  end

  @doc """
  Location params from a discovered location, linked to it by `home_assistant_id`.
  Its parent is the inventory location of its floor; a floor, or an area without
  floor, goes into the only top level site or building when there is exactly one.
  """
  @spec location_params(DiscoveredLocation.t(), Snapshot.t()) :: map()
  def location_params(%DiscoveredLocation{} = discovered, %Snapshot{} = snapshot) do
    %{
      "name" => discovered.name,
      "kind" => Atom.to_string(discovered.kind),
      "parent_id" => discovered.parent_id || default_parent_id(snapshot),
      "home_assistant_id" => discovered.reference
    }
  end

  defp default_parent_id(snapshot) do
    case Enum.filter(snapshot.locations, &root_place?/1) do
      [%Location{id: id}] -> id
      _none_or_several -> nil
    end
  end

  defp root_place?(%Location{parent_id: nil, kind: kind}), do: kind in @root_location_kinds
  defp root_place?(_location), do: false

  defp network_params_of(%DiscoveredDevice{role: nil}), do: %{}

  defp network_params_of(%DiscoveredDevice{role: role}),
    do: %{"kind" => "network", "network_role" => Atom.to_string(role)}

  defp dns_names(discovered, ip, snapshot) do
    domain = network_domain(snapshot, ip)

    discovered.observations
    |> Enum.filter(&(Observation.dns_record?(&1) and &1.ip == ip and &1.hostname != nil))
    |> Enum.map(fn observation ->
      if observation.domain in [nil, domain],
        do: observation.hostname,
        else: Observation.fqdn(observation)
    end)
    |> Enum.filter(&Interface.valid_dns_name?/1)
    |> Enum.uniq()
    |> Enum.join(", ")
  end

  defp interfaces(%DiscoveredDevice{macs: [], ips: [ip | _ips]} = discovered, snapshot) do
    %{
      "0" => %{
        "ip" => ip,
        "assignment" => "static",
        "network_id" => network_id(snapshot, ip),
        "dns_names" => dns_names(discovered, ip, snapshot)
      }
    }
  end

  defp interfaces(%DiscoveredDevice{macs: macs} = discovered, snapshot) do
    macs
    |> Enum.with_index()
    |> Map.new(fn {mac, position} ->
      reservation =
        Enum.find(discovered.observations, &(&1.mac == mac and &1.source == :kea_reservation))

      ip = interface_ip(reservation, discovered, position)

      {Integer.to_string(position),
       %{
         "mac" => mac,
         "ip" => ip,
         "assignment" =>
           if(reservation, do: "reserved", else: assignment_without_reservation(ip)),
         "network_id" => network_id(snapshot, ip),
         "dns_names" => if(ip, do: dns_names(discovered, ip, snapshot), else: "")
       }}
    end)
  end

  defp interface_ip(%Observation{ip: ip}, _discovered, _position), do: ip
  defp interface_ip(nil, %DiscoveredDevice{ips: [ip | _ips]}, 0), do: ip
  defp interface_ip(nil, _discovered, _position), do: nil

  defp assignment_without_reservation(nil), do: "dynamic"
  defp assignment_without_reservation(_ip), do: "static"

  defp network_domain(snapshot, ip) do
    Enum.find_value(snapshot.networks, &(Network.contains?(&1, ip) && &1.domain))
  end

  defp network_id(_snapshot, nil), do: nil

  defp network_id(snapshot, ip) do
    Enum.find_value(snapshot.networks, &(Network.contains?(&1, ip) && &1.id))
  end
end
