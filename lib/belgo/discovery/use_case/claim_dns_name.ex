defmodule Belgo.Discovery.UseCase.ClaimDnsName do
  @moduledoc """
  Claims a DNS name reported by a provider as a DNS name of a device interface or of
  a virtual IP. Params are `{discovered_dns_name, target}`, the target being
  `{:devices, device_id, interface_index}` (position in the device interfaces, which
  must have an address) or `{:virtual_ips, virtual_ip_id}`. The name is stored short
  when its domain is the one of the target network. Returns `{collection, record}`,
  the updated record being pushed like any saved one.
  """

  use Belgo.UseCase

  alias Belgo.Discovery.DnsNames
  alias Belgo.Discovery.DnsNames.DiscoveredDnsName
  alias Belgo.Inventory
  alias Belgo.Inventory.Codec
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.Transaction
  alias Belgo.Inventory.VirtualIp

  @impl Box.UseCase
  def validate({%DiscoveredDnsName{}, {:devices, device_id, interface_index}} = params, options)
      when is_binary(device_id) and is_integer(interface_index) do
    with {:ok, _user} <- authorize(options), do: {:ok, params}
  end

  def validate({%DiscoveredDnsName{}, {:virtual_ips, virtual_ip_id}} = params, options)
      when is_binary(virtual_ip_id) do
    with {:ok, _user} <- authorize(options), do: {:ok, params}
  end

  def validate(_params, _options), do: {:error, :invalid_params}

  @impl Box.UseCase
  def run(multi, {discovered, target}, options) do
    snapshot =
      options
      |> Keyword.get(:transaction, [])
      |> Keyword.get(:server, Inventory.Store)
      |> Inventory.snapshot()

    case add_name(multi, snapshot, discovered, target) do
      {:ok, multi} ->
        multi

      {:error, reason} ->
        Ecto.Multi.run(multi, :record, fn _snapshot, _changes -> {:error, reason} end)
    end
  end

  @impl Box.UseCase
  def after_run(%{record: %Device{} = device}, _options),
    do: Belgo.Sync.after_save(:devices, device)

  def after_run(%{record: %VirtualIp{} = virtual_ip}, _options),
    do: Belgo.Sync.after_save(:virtual_ips, virtual_ip)

  @impl Box.UseCase
  def return(%{record: record}, _options), do: record

  defp add_name(multi, snapshot, discovered, {:devices, device_id, interface_index}) do
    with {:ok, device} <- Snapshot.fetch(snapshot, :devices, device_id),
         {:ok, interface} <- addressed_interface(device, interface_index) do
      name = DnsNames.stored_name(discovered, DnsNames.network_domain(snapshot, interface))

      {:ok,
       Transaction.update_with(multi, :record, :devices, device_id, fn record ->
         attributes = Codec.encode(record)

         interfaces =
           attributes
           |> Map.get("interfaces", [])
           |> List.update_at(interface_index, &add_dns_name(&1, name))

         Map.put(attributes, "interfaces", interfaces)
       end)}
    end
  end

  defp add_name(multi, snapshot, discovered, {:virtual_ips, virtual_ip_id}) do
    with {:ok, virtual_ip} <- Snapshot.fetch(snapshot, :virtual_ips, virtual_ip_id) do
      name = DnsNames.stored_name(discovered, DnsNames.network_domain(snapshot, virtual_ip))

      {:ok,
       Transaction.update_with(multi, :record, :virtual_ips, virtual_ip_id, fn record ->
         add_dns_name(Codec.encode(record), name)
       end)}
    end
  end

  defp addressed_interface(device, interface_index) do
    case Enum.find(DnsNames.addressed_interfaces(device), &(elem(&1, 1) == interface_index)) do
      {interface, _index} -> {:ok, interface}
      nil -> {:error, :interface_without_address}
    end
  end

  defp add_dns_name(attributes, name) do
    names = Map.get(attributes, "dns_names") || []
    if name in names, do: attributes, else: Map.put(attributes, "dns_names", names ++ [name])
  end
end
