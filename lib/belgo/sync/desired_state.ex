defmodule Belgo.Sync.DesiredState do
  @moduledoc """
  What the external systems (AdGuard Home, OPNsense, Omada controller) must contain
  according to the inventory. Synchronisation targets diff this against their
  actual state.

    * `dns_records` – name to address (AdGuard rewrites, Unbound host overrides)
    * `dhcp_reservations` – MAC to address (OPNsense static mappings, Omada fixed IPs)
    * `client_names` – MAC to display name (Omada clients)
    * `clients` – one per addressed device, with all its MAC and IP addresses
      (AdGuard Home persistent clients)

  Every DHCP reservation and client name of a device uses the device hostname or
  name, never the interface name, since it is the same machine. DNS records come
  only from the interfaces' `dns_names` (the hostname never creates one): a name
  without a dot is completed with the network domain, others are used as is.
  """

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Snapshot
  alias Belgo.Network.IpAddress

  defmodule DnsRecord do
    @moduledoc """
    A DNS name resolving to an address. `name` is the full name; `host` and `domain`
    split it for systems storing them apart (Unbound). `domain` is `nil` for a bare
    name, when the network has no domain.
    """
    defstruct [:name, :host, :domain, :address, :description, :device_id]

    @type t :: %__MODULE__{
            name: String.t(),
            host: String.t(),
            domain: String.t() | nil,
            address: String.t(),
            description: String.t(),
            device_id: String.t()
          }
  end

  defmodule DhcpReservation do
    @moduledoc "A MAC address always leased the same address."
    defstruct [:mac, :address, :hostname, :description, :network_id, :cidr, :device_id]

    @type t :: %__MODULE__{
            mac: String.t(),
            address: String.t(),
            hostname: String.t(),
            description: String.t(),
            network_id: String.t() | nil,
            cidr: String.t() | nil,
            device_id: String.t()
          }
  end

  defmodule ClientName do
    @moduledoc "The name a network client is displayed with."
    defstruct [:mac, :name, :device_id]

    @type t :: %__MODULE__{mac: String.t(), name: String.t(), device_id: String.t()}
  end

  defmodule Client do
    @moduledoc """
    A device as a DNS client (AdGuard Home persistent client): its name, every MAC
    and IP address identifying it, its kind and tags.
    """
    @enforce_keys [:device_id, :name, :ids]
    defstruct [:device_id, :name, :ids, :kind, tags: []]

    @type t :: %__MODULE__{
            device_id: String.t(),
            name: String.t(),
            ids: [String.t()],
            kind: atom(),
            tags: [String.t()]
          }
  end

  defstruct dns_records: [], dhcp_reservations: [], client_names: [], clients: []

  @type t :: %__MODULE__{
          dns_records: [DnsRecord.t()],
          dhcp_reservations: [DhcpReservation.t()],
          client_names: [ClientName.t()],
          clients: [Client.t()]
        }

  @doc "Computes the desired state of the whole inventory."
  @spec build(Snapshot.t()) :: t()
  def build(%Snapshot{} = snapshot) do
    network_by_id = Snapshot.index(snapshot, :networks)
    entries = Enum.map(snapshot.devices, &device_entries(&1, network_by_id))

    %__MODULE__{
      dns_records:
        entries
        |> Enum.flat_map(& &1.dns_records)
        |> Enum.sort_by(&{&1.name, &1.address}),
      dhcp_reservations:
        entries
        |> Enum.flat_map(& &1.dhcp_reservations)
        |> Enum.sort_by(&IpAddress.sort_key(&1.address)),
      client_names:
        entries
        |> Enum.flat_map(& &1.client_names)
        |> Enum.sort_by(& &1.mac),
      clients:
        entries
        |> Enum.flat_map(& &1.clients)
        |> Enum.sort_by(& &1.device_id)
    }
  end

  @doc "Keeps only the entries produced by one device."
  @spec for_device(t(), String.t()) :: t()
  def for_device(%__MODULE__{} = desired_state, device_id) do
    keep = fn entries -> Enum.filter(entries, &(&1.device_id == device_id)) end

    %__MODULE__{
      dns_records: keep.(desired_state.dns_records),
      dhcp_reservations: keep.(desired_state.dhcp_reservations),
      client_names: keep.(desired_state.client_names),
      clients: keep.(desired_state.clients)
    }
  end

  defp device_entries(device, network_by_id) do
    named_interfaces = name_interfaces(device)

    %{
      dns_records: Enum.flat_map(named_interfaces, &dns_records(device, &1, network_by_id)),
      dhcp_reservations:
        Enum.flat_map(named_interfaces, &dhcp_reservation(device, &1, network_by_id)),
      client_names:
        device.interfaces
        |> Enum.filter(& &1.mac)
        |> Enum.map(&%ClientName{mac: &1.mac, name: device.name, device_id: device.id}),
      clients: client(device)
    }
  end

  defp client(device) do
    macs = for %{mac: mac} <- device.interfaces, mac != nil, do: mac
    ips = for %{ip: ip} <- device.interfaces, ip != nil, do: ip

    case Enum.uniq(macs ++ ips) do
      [] ->
        []

      ids ->
        [
          %Client{
            device_id: device.id,
            name: device.name,
            ids: ids,
            kind: device.kind,
            tags: device.tags
          }
        ]
    end
  end

  defp name_interfaces(device) do
    hostname = Device.hostname(device)

    device.interfaces
    |> Enum.filter(& &1.ip)
    |> Enum.map(&{hostname, &1})
  end

  defp dns_records(device, {_hostname, interface}, network_by_id) do
    domain = network_field(network_by_id, interface.network_id, :domain)
    Enum.map(interface.dns_names, &dns_record(device, interface, &1, domain))
  end

  defp dns_record(device, interface, name, network_domain) do
    {host, domain} = split_name(name, network_domain)

    %DnsRecord{
      name: Enum.join(Enum.reject([host, domain], &is_nil/1), "."),
      host: host,
      domain: domain,
      address: interface.ip,
      description: Device.interface_label(device, interface),
      device_id: device.id
    }
  end

  defp split_name(name, network_domain) do
    case String.split(name, ".", parts: 2) do
      [host, domain] -> {host, domain}
      [host] -> {host, network_domain}
    end
  end

  defp dhcp_reservation(
         device,
         {hostname, %{assignment: :reserved, mac: mac} = interface},
         network_by_id
       )
       when is_binary(mac) do
    [
      %DhcpReservation{
        mac: mac,
        address: interface.ip,
        hostname: hostname,
        description: Device.interface_label(device, interface),
        network_id: interface.network_id,
        cidr: network_field(network_by_id, interface.network_id, :cidr),
        device_id: device.id
      }
    ]
  end

  defp dhcp_reservation(_device, _named_interface, _network_by_id), do: []

  defp network_field(network_by_id, network_id, field) do
    case Map.fetch(network_by_id, network_id) do
      {:ok, network} -> Map.fetch!(network, field)
      :error -> nil
    end
  end
end
