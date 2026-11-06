defmodule Belgo.Inventory.AddressAllocation do
  @moduledoc """
  Suggests addresses from the logical ranges of the networks (`Network.ranges`): the
  first address of a range tied to a device kind that nothing uses. Used addresses
  are the inventory's (interfaces, virtual IPs, gateways), the ones providers report
  (reservations, leases, DNS records) and the ones already chosen in the form. The
  network and broadcast addresses are never suggested. Pure functions.
  """

  alias Belgo.Discovery.Observation
  alias Belgo.Inventory.AddressRange
  alias Belgo.Inventory.Interface
  alias Belgo.Inventory.Network
  alias Belgo.Inventory.Snapshot
  alias Belgo.Network.Cidr
  alias Belgo.Network.IpAddress

  defmodule Suggestion do
    @moduledoc "A suggested address, with the network and the range it comes from."
    @enforce_keys [:ip, :network_id, :range]
    defstruct [:ip, :network_id, :range]

    @type t :: %__MODULE__{ip: String.t(), network_id: String.t(), range: AddressRange.t()}
  end

  @doc "The ranges tied to a device kind, in network order (one network only when given)."
  @spec ranges_for(Snapshot.t(), atom(), String.t() | nil) :: [{Network.t(), AddressRange.t()}]
  def ranges_for(%Snapshot{} = snapshot, kind, network_id \\ nil) do
    for network <- snapshot.networks,
        network_id in [nil, network.id],
        range <- Enum.sort_by(network.ranges, &IpAddress.sort_key(&1.start)),
        range.kind == kind,
        do: {network, range}
  end

  @doc "Returns `true` when the address belongs to a range tied to the kind."
  @spec in_kind_range?(Snapshot.t(), atom(), String.t() | nil) :: boolean()
  def in_kind_range?(_snapshot, _kind, nil), do: false

  def in_kind_range?(%Snapshot{} = snapshot, kind, address),
    do:
      Enum.any?(ranges_for(snapshot, kind), fn {_network, range} ->
        AddressRange.contains?(range, address)
      end)

  @doc """
  The addresses in use: the inventory's except those of `device_id` (being edited),
  and every address providers report.
  """
  @spec used_addresses(Snapshot.t(), [Observation.t()], String.t() | nil) :: MapSet.t(String.t())
  def used_addresses(%Snapshot{} = snapshot, observations, device_id) do
    interface_addresses =
      for device <- snapshot.devices,
          device.id != device_id,
          %{ip: ip} <- device.interfaces,
          ip != nil,
          do: ip

    [
      interface_addresses,
      Enum.map(snapshot.virtual_ips, & &1.ip),
      for(%{gateway: gateway} <- snapshot.networks, gateway != nil, do: gateway),
      for(%{ip: ip} <- observations, ip != nil, do: ip)
    ]
    |> Enum.concat()
    |> MapSet.new()
  end

  @doc "Suggests the first free address of the kind's ranges, `nil` when none is free."
  @spec suggest(Snapshot.t(), atom(), MapSet.t(String.t()), String.t() | nil) ::
          Suggestion.t() | nil
  def suggest(%Snapshot{} = snapshot, kind, used, network_id \\ nil) do
    snapshot
    |> ranges_for(kind, network_id)
    |> Enum.find_value(fn {network, range} ->
      case first_free(network, range, used) do
        nil -> nil
        ip -> %Suggestion{ip: ip, network_id: network.id, range: range}
      end
    end)
  end

  defp first_free(network, range, used) do
    with {:ok, cidr} <- Cidr.parse(network.cidr),
         {:ok, first} <- IpAddress.parse(range.start),
         {:ok, last} <- IpAddress.parse(range.end) do
      reserved = MapSet.new([cidr.address, Cidr.last_address(cidr)])

      IpAddress.to_integer(first)..IpAddress.to_integer(last)//1
      |> Stream.map(&IpAddress.from_integer(&1, first))
      |> Stream.reject(&MapSet.member?(reserved, &1))
      |> Stream.map(&IpAddress.format/1)
      |> Enum.find(&(not MapSet.member?(used, &1)))
    else
      _invalid -> nil
    end
  end

  @doc """
  Suggestions for interfaces whose address is missing or outside the ranges of the
  device kind, by position, from the interface's network when set; each gets a
  distinct address. Values are not changed: the form offers them.
  """
  @spec suggest_interfaces(Snapshot.t(), atom() | nil, [Interface.t()], MapSet.t(String.t())) ::
          %{non_neg_integer() => Suggestion.t()}
  def suggest_interfaces(_snapshot, nil, _interfaces, _used), do: %{}

  def suggest_interfaces(%Snapshot{} = snapshot, kind, interfaces, used) do
    used = MapSet.union(used, MapSet.new(for %{ip: ip} <- interfaces, ip != nil, do: ip))

    {suggestions, _used} =
      interfaces
      |> Enum.with_index()
      |> Enum.reject(fn {interface, _index} -> in_kind_range?(snapshot, kind, interface.ip) end)
      |> Enum.reduce({%{}, used}, fn {interface, index}, {suggestions, used} ->
        # Within the interface's network when it has one, any network otherwise.
        case suggest(snapshot, kind, used, interface.network_id) do
          nil -> {suggestions, used}
          suggestion -> {Map.put(suggestions, index, suggestion), MapSet.put(used, suggestion.ip)}
        end
      end)

    suggestions
  end

  @new_entry "new"
  @interfaces_key "interfaces"
  @sort_key "interfaces_sort"

  @doc """
  Fills interface addresses in device form params from the ranges of the device
  kind: when the kind changes (`previous_kind`), interfaces without address or
  outside the kind's ranges get one; an added interface (`"new"` in
  `interfaces_sort`) gets one. A suggested dynamic interface becomes reserved (with a
  MAC) or static. Returns the params and the suggestions by interface position.
  """
  @spec suggest_params(map(), atom() | nil, Snapshot.t(), MapSet.t(String.t())) ::
          {map(), %{non_neg_integer() => Suggestion.t()}}
  def suggest_params(params, previous_kind, %Snapshot{} = snapshot, used) do
    kind = parse_kind(Map.get(params, "kind"))
    sort = List.wrap(Map.get(params, @sort_key))
    adding? = @new_entry in sort

    if kind && ranges_for(snapshot, kind) != [] && (kind != previous_kind or adding?) do
      fill(params, kind, kind != previous_kind, snapshot, used)
    else
      {params, %{}}
    end
  end

  defp fill(params, kind, kind_changed?, snapshot, used) do
    interfaces = Map.get(params, @interfaces_key) || %{}
    {sort, interfaces, added} = materialize_new_entries(List.wrap(params[@sort_key]), interfaces)

    targets =
      Enum.filter(Map.keys(interfaces), fn index ->
        index in added or (kind_changed? and needs_address?(interfaces[index], snapshot, kind))
      end)

    used =
      interfaces
      |> Map.drop(targets)
      |> Enum.flat_map(fn {_index, interface} -> List.wrap(blank_to_nil(interface["ip"])) end)
      |> MapSet.new()
      |> MapSet.union(used)

    {interfaces, suggestions, _used} =
      targets
      |> Enum.sort_by(&String.to_integer/1)
      |> Enum.reduce({interfaces, %{}, used}, &suggest_interface(&1, &2, kind, snapshot))

    params =
      params
      |> Map.put(@interfaces_key, interfaces)
      |> Map.put(@sort_key, sort)

    {params, suggestions}
  end

  defp suggest_interface(index, {interfaces, suggestions, used}, kind, snapshot) do
    interface = interfaces[index]
    network_id = blank_to_nil(interface["network_id"])

    network_id =
      if network_id && ranges_for(snapshot, kind, network_id) != [], do: network_id, else: nil

    case suggest(snapshot, kind, used, network_id) do
      nil ->
        {interfaces, suggestions, used}

      suggestion ->
        interface =
          interface
          |> Map.put("ip", suggestion.ip)
          |> Map.put("network_id", suggestion.network_id)
          |> managed_assignment()

        {Map.put(interfaces, index, interface),
         Map.put(suggestions, String.to_integer(index), suggestion),
         MapSet.put(used, suggestion.ip)}
    end
  end

  # "new" sort entries become explicit positions, so the added interface can be filled.
  defp materialize_new_entries(sort, interfaces) do
    next =
      interfaces
      |> Map.keys()
      |> Enum.map(&String.to_integer/1)
      |> Enum.max(fn -> -1 end)
      |> Kernel.+(1)

    {sort, interfaces, added, _next} =
      Enum.reduce(sort, {[], interfaces, [], next}, fn
        @new_entry, {sort, interfaces, added, position} ->
          index = Integer.to_string(position)
          {sort ++ [index], Map.put(interfaces, index, %{}), [index | added], position + 1}

        index, {sort, interfaces, added, position} ->
          {sort ++ [index], interfaces, added, position}
      end)

    {sort, interfaces, added}
  end

  defp needs_address?(interface, snapshot, kind) do
    case blank_to_nil(interface["ip"]) do
      nil -> true
      ip -> not in_kind_range?(snapshot, kind, ip)
    end
  end

  # A dynamic lease does not keep an address: the suggested one is reserved (or static
  # without MAC). New interfaces keep the default assignment.
  defp managed_assignment(%{"assignment" => "dynamic", "mac" => mac} = interface)
       when mac not in [nil, ""],
       do: Map.put(interface, "assignment", "reserved")

  defp managed_assignment(%{"assignment" => "dynamic"} = interface),
    do: Map.put(interface, "assignment", "static")

  defp managed_assignment(interface), do: interface

  defp parse_kind(nil), do: nil

  defp parse_kind(name),
    do: Enum.find(Belgo.Inventory.Device.kinds(), &(Atom.to_string(&1) == to_string(name)))

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value
end
