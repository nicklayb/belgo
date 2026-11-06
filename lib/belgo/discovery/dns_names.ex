defmodule Belgo.Discovery.DnsNames do
  @moduledoc """
  DNS names reported by providers (Unbound host overrides, AdGuard rewrites) that
  Belgo does not own yet, although they resolve to an address of an inventory
  device or virtual IP: they can be claimed as a DNS name of a device interface or
  of a virtual IP. Pure functions.

  The suggestion is the interface or virtual IP holding the address; any other
  target with an address can be chosen when claiming. Names duplicated on a
  provider (`Correlation.Conflict`) are left out, they must be fixed there first.
  """

  alias Belgo.Discovery.Observation
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Identifier
  alias Belgo.Inventory.Interface
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.VirtualIp
  alias Belgo.Network.IpAddress
  alias Belgo.Sync.DesiredState

  defmodule DiscoveredDnsName do
    @moduledoc """
    A DNS name unknown to Belgo resolving to an inventory address, with the suggested
    target: `device_id` and `interface_index` (position in the device interfaces), or
    `virtual_ip_id`.
    """
    @enforce_keys [:id, :name, :hostname, :ip]
    defstruct [
      :id,
      :name,
      :hostname,
      :domain,
      :ip,
      :device_id,
      :interface_index,
      :virtual_ip_id,
      providers: [],
      observations: []
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            hostname: String.t(),
            domain: String.t() | nil,
            ip: String.t(),
            device_id: String.t() | nil,
            interface_index: non_neg_integer() | nil,
            virtual_ip_id: String.t() | nil,
            providers: [atom()],
            observations: [Observation.t()]
          }
  end

  @id_prefix "dns-"

  @doc """
  Lists the unowned DNS names resolving to an inventory interface address, sorted by
  name. `conflicting_names` are the names duplicated on a provider.
  """
  @spec build(Snapshot.t(), [Observation.t()], DesiredState.t(), [String.t()]) ::
          [DiscoveredDnsName.t()]
  def build(
        %Snapshot{} = snapshot,
        observations,
        %DesiredState{} = desired_state,
        conflicting_names
      ) do
    owned_names = MapSet.new(desired_state.dns_records, & &1.name)
    excluded_names = MapSet.union(owned_names, MapSet.new(conflicting_names))
    target_by_ip = target_by_ip(snapshot)

    observations
    |> Enum.filter(&claimable?(&1, excluded_names, target_by_ip))
    |> Enum.group_by(&{Observation.fqdn(&1), &1.ip})
    |> Enum.map(fn {{name, ip}, name_observations} ->
      discovered(name, ip, name_observations, Map.fetch!(target_by_ip, ip))
    end)
    |> Enum.sort_by(&{&1.name, IpAddress.sort_key(&1.ip)})
  end

  @doc """
  The name to store in the interface `dns_names`: the short hostname when the domain
  is the one of the interface network (or unknown), the full name otherwise.
  """
  @spec stored_name(DiscoveredDnsName.t(), String.t() | nil) :: String.t()
  def stored_name(%DiscoveredDnsName{domain: domain, hostname: hostname}, network_domain)
      when domain in [nil, network_domain],
      do: hostname

  def stored_name(%DiscoveredDnsName{name: name}, _network_domain), do: name

  @doc "The domain of the network of an interface or a virtual IP (declared, else by range)."
  @spec network_domain(Snapshot.t(), Interface.t() | VirtualIp.t()) :: String.t() | nil
  def network_domain(%Snapshot{} = snapshot, %{network_id: network_id, ip: ip}),
    do: DesiredState.network_domain(snapshot.networks, network_id, ip)

  @doc "The interfaces of a device a DNS name can be given to (those with an address)."
  @spec addressed_interfaces(Device.t()) :: [{Interface.t(), non_neg_integer()}]
  def addressed_interfaces(%Device{interfaces: interfaces}) do
    interfaces
    |> Enum.with_index()
    |> Enum.filter(fn {interface, _index} -> interface.ip != nil end)
  end

  defp claimable?(observation, excluded_names, target_by_ip) do
    Observation.dns_record?(observation) and observation.hostname != nil and
      Map.has_key?(target_by_ip, observation.ip) and
      not MapSet.member?(excluded_names, Observation.fqdn(observation))
  end

  defp discovered(name, ip, observations, target) do
    observation = hd(observations)

    %DiscoveredDnsName{
      id: @id_prefix <> Identifier.slugify("#{name} #{ip}"),
      name: name,
      hostname: observation.hostname,
      domain: observation.domain,
      ip: ip,
      device_id: target_device_id(target),
      interface_index: target_interface_index(target),
      virtual_ip_id: target_virtual_ip_id(target),
      providers: providers(observations),
      observations: observations
    }
  end

  defp providers(observations) do
    observations
    |> Enum.map(& &1.provider)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp target_device_id({:interface, device, _index}), do: device.id
  defp target_device_id({:virtual_ip, _virtual_ip}), do: nil
  defp target_interface_index({:interface, _device, index}), do: index
  defp target_interface_index({:virtual_ip, _virtual_ip}), do: nil
  defp target_virtual_ip_id({:interface, _device, _index}), do: nil
  defp target_virtual_ip_id({:virtual_ip, virtual_ip}), do: virtual_ip.id

  # Interfaces and virtual IPs by address (a virtual IP wins on a shared address).
  defp target_by_ip(snapshot) do
    interfaces =
      for device <- snapshot.devices,
          {interface, index} <- Enum.with_index(device.interfaces),
          interface.ip != nil,
          into: %{},
          do: {interface.ip, {:interface, device, index}}

    Enum.into(snapshot.virtual_ips, interfaces, &{&1.ip, {:virtual_ip, &1}})
  end
end
