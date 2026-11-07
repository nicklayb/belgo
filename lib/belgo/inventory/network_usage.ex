defmodule Belgo.Inventory.NetworkUsage do
  @moduledoc """
  Who holds the addresses of a network, for its page: device interfaces and virtual
  IPs in it (declared network, else by address), and its gateway when nothing else
  holds that address. Each logical range becomes one row per address, free ones
  included; a device whose kind differs from the range's is flagged. Addresses held
  outside every range are listed apart. Pure functions.
  """

  alias Belgo.Inventory.AddressRange
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Network
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.VirtualIp
  alias Belgo.Network.IpAddress

  @maximum_range_rows 1024

  defmodule Holder do
    @moduledoc """
    What holds an address: a device (with its interface name), a virtual IP or the
    network's gateway. `kind_mismatch?` marks a device of another kind than its range.
    """
    @enforce_keys [:type, :name]
    defstruct [:type, :id, :name, :interface_name, :device_kind, kind_mismatch?: false]

    @type t :: %__MODULE__{
            type: :device | :virtual_ip | :gateway,
            id: String.t() | nil,
            name: String.t(),
            interface_name: String.t() | nil,
            device_kind: atom() | nil,
            kind_mismatch?: boolean()
          }
  end

  defmodule Row do
    @moduledoc "An address and what holds it (none when free)."
    @enforce_keys [:address]
    defstruct [:address, holders: []]

    @type t :: %__MODULE__{address: String.t(), holders: [Holder.t()]}
  end

  @doc "The holders of the network's addresses, by address."
  @spec holders_by_address(Snapshot.t(), Network.t()) :: %{String.t() => [Holder.t()]}
  def holders_by_address(%Snapshot{} = snapshot, %Network{} = network) do
    device_holders =
      for device <- snapshot.devices,
          interface <- device.interfaces,
          in_network?(interface, network),
          do: {interface.ip, device_holder(device, interface)}

    virtual_ip_holders =
      for %VirtualIp{} = virtual_ip <- snapshot.virtual_ips,
          in_network?(virtual_ip, network),
          do:
            {virtual_ip.ip, %Holder{type: :virtual_ip, id: virtual_ip.id, name: virtual_ip.name}}

    (device_holders ++ virtual_ip_holders)
    |> Enum.group_by(fn {address, _holder} -> address end, fn {_address, holder} -> holder end)
    |> put_gateway(network.gateway)
  end

  # The gateway address is named when no device or virtual IP holds it.
  defp put_gateway(holders_by_address, nil), do: holders_by_address

  defp put_gateway(holders_by_address, gateway),
    do: Map.put_new(holders_by_address, gateway, [%Holder{type: :gateway, name: "Gateway"}])

  @doc """
  One row per address of the range, in order, holders flagged when their kind is not
  the range's. `{:too_large, size}` past #{@maximum_range_rows} addresses.
  """
  @spec range_rows(AddressRange.t(), %{String.t() => [Holder.t()]}) ::
          {:ok, [Row.t()]} | {:too_large, pos_integer()}
  def range_rows(%AddressRange{} = range, holders_by_address) do
    with {:ok, first} <- IpAddress.parse(range.start),
         {:ok, last} <- IpAddress.parse(range.end) do
      first_value = IpAddress.to_integer(first)
      size = IpAddress.to_integer(last) - first_value + 1

      if size > @maximum_range_rows do
        {:too_large, size}
      else
        {:ok,
         for value <- first_value..(first_value + size - 1)//1 do
           address = IpAddress.format(IpAddress.from_integer(value, first))
           holders = Map.get(holders_by_address, address, [])
           %Row{address: address, holders: Enum.map(holders, &flag(&1, range.kind))}
         end}
      end
    else
      :error -> {:ok, []}
    end
  end

  @doc "Held addresses outside every logical range of the network, in order."
  @spec outside_rows(Network.t(), %{String.t() => [Holder.t()]}) :: [Row.t()]
  def outside_rows(%Network{} = network, holders_by_address) do
    holders_by_address
    |> Enum.reject(fn {address, _holders} ->
      Enum.any?(network.ranges, &AddressRange.contains?(&1, address))
    end)
    |> Enum.sort_by(fn {address, _holders} -> IpAddress.sort_key(address) end)
    |> Enum.map(fn {address, holders} -> %Row{address: address, holders: holders} end)
  end

  @doc "Number of rows of a range holding at least one device or virtual IP."
  @spec used_count([Row.t()]) :: non_neg_integer()
  def used_count(rows), do: Enum.count(rows, &(&1.holders != []))

  defp device_holder(%Device{} = device, interface) do
    %Holder{
      type: :device,
      id: device.id,
      name: device.name,
      interface_name: interface.name,
      device_kind: device.kind
    }
  end

  defp in_network?(%{ip: nil}, _network), do: false

  defp in_network?(%{network_id: network_id}, network) when is_binary(network_id),
    do: network_id == network.id

  defp in_network?(%{ip: ip}, network), do: Network.contains?(network, ip)

  defp flag(%Holder{type: :device} = holder, kind) when not is_nil(kind),
    do: %{holder | kind_mismatch?: holder.device_kind != kind}

  defp flag(holder, _kind), do: holder
end
