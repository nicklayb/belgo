defmodule Belgo.Search do
  @moduledoc """
  Searches the inventory (devices and virtual IPs), and optionally the discovery, by
  almost anything: name, hostname, MAC, IP, DNS names, tags, notes, location,
  metadata… Pure functions.

  Matching is case insensitive; MAC addresses also match without separators
  (`0200000010` finds `02:00:00:00:00:10`). Exact matches come first, then prefixes,
  then any substring.
  """

  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.Correlation.DiscoveredDevice
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Snapshot
  alias Belgo.Topology.Physical

  @default_limit 20
  @mac_separators ~r/[:\-\.\s]/
  @score_by_match %{exact: 0, prefix: 1, contains: 2}

  defmodule Result do
    @moduledoc "A search hit: what was found, and which field matched."
    @enforce_keys [:type, :id, :title, :field, :value]
    defstruct [:type, :id, :title, :subtitle, :field, :value, score: 2]

    @type t :: %__MODULE__{
            type: :device | :virtual_ip | :discovered,
            id: String.t(),
            title: String.t(),
            subtitle: String.t() | nil,
            field: String.t(),
            value: String.t(),
            score: non_neg_integer()
          }
  end

  @doc """
  Runs a search. Options: `:discovery` (a `Correlation` to include discovered
  devices) and `:limit` (#{@default_limit} by default).
  """
  @spec run(Snapshot.t(), String.t(), Keyword.t()) :: [Result.t()]
  def run(%Snapshot{} = snapshot, query, options \\ []) do
    case normalize(query) do
      "" ->
        []

      normalized ->
        discovered =
          case Keyword.get(options, :discovery) do
            %Correlation{} = correlation -> discovered_devices(correlation)
            nil -> []
          end

        (Enum.flat_map(snapshot.devices, &device_result(&1, snapshot, normalized)) ++
           Enum.flat_map(snapshot.virtual_ips, &virtual_ip_result(&1, normalized)) ++
           Enum.flat_map(discovered, &discovered_result(&1, normalized)))
        |> Enum.sort_by(&{&1.score, &1.type == :discovered, String.downcase(&1.title)})
        |> Enum.take(Keyword.get(options, :limit, @default_limit))
    end
  end

  @doc "Returns `true` when a discovered device matches the query (used by filters)."
  @spec discovered_match?(DiscoveredDevice.t(), String.t()) :: boolean()
  def discovered_match?(%DiscoveredDevice{} = discovered, query) do
    case normalize(query) do
      "" -> true
      normalized -> discovered_result(discovered, normalized) != []
    end
  end

  defp device_result(device, snapshot, query) do
    device
    |> device_fields(snapshot)
    |> best_match(query)
    |> to_result(fn {field, value, score} ->
      %Result{
        type: :device,
        id: device.id,
        title: device.name,
        subtitle: Device.hostname(device),
        field: field,
        value: value,
        score: score
      }
    end)
  end

  defp virtual_ip_result(virtual_ip, query) do
    ([
       {"Name", virtual_ip.name},
       {"Identifier", virtual_ip.id},
       {"IP", virtual_ip.ip},
       {"Notes", virtual_ip.notes}
     ] ++ Enum.map(virtual_ip.dns_names, &{"DNS name", &1}))
    |> best_match(query)
    |> to_result(fn {field, value, score} ->
      %Result{
        type: :virtual_ip,
        id: virtual_ip.id,
        title: virtual_ip.name,
        subtitle: virtual_ip.ip,
        field: field,
        value: value,
        score: score
      }
    end)
  end

  defp discovered_result(discovered, query) do
    discovered
    |> discovered_fields()
    |> best_match(query)
    |> to_result(fn {field, value, score} ->
      %Result{
        type: :discovered,
        id: discovered.id,
        title:
          discovered.hostname || discovered.description ||
            List.first(discovered.ips ++ discovered.macs),
        subtitle:
          discovered.observations
          |> Enum.map(& &1.provider)
          |> Enum.uniq()
          |> Enum.join(", "),
        field: field,
        value: value,
        score: score
      }
    end)
  end

  defp to_result(nil, _builder), do: []
  defp to_result(match, builder), do: [builder.(match)]

  defp device_fields(device, snapshot) do
    location =
      snapshot
      |> Physical.device_path(device)
      |> Map.fetch!(:locations)
      |> Enum.map_join(" / ", & &1.name)

    [
      {"Name", device.name},
      {"Hostname", Device.hostname(device)},
      {"Identifier", device.id},
      {"Notes", device.notes},
      {"Location", location}
    ] ++
      Enum.map(device.tags, &{"Tag", &1}) ++
      Enum.map(device.metadata, &{&1.label, &1.value}) ++
      Enum.flat_map(device.interfaces, &interface_fields/1)
  end

  defp interface_fields(interface) do
    [{"Interface", interface.name}, {"MAC", interface.mac}, {"IP", interface.ip}] ++
      Enum.map(interface.dns_names, &{"DNS name", &1})
  end

  defp discovered_fields(discovered) do
    [{"Hostname", discovered.hostname}, {"Description", discovered.description}] ++
      Enum.map(discovered.macs, &{"MAC", &1}) ++
      Enum.map(discovered.ips, &{"IP", &1}) ++
      Enum.flat_map(discovered.observations, fn observation ->
        [
          {"Name", observation.hostname},
          {"Description", observation.description},
          {"Seen in", Atom.to_string(observation.provider)}
        ]
      end)
  end

  defp best_match(fields, query) do
    fields
    |> Enum.reject(fn {_field, value} -> value in [nil, ""] end)
    |> Enum.flat_map(fn {field, value} ->
      case match(value, query, field) do
        nil -> []
        kind -> [{field, value, Map.fetch!(@score_by_match, kind)}]
      end
    end)
    |> Enum.min_by(fn {_field, _value, score} -> score end, fn -> nil end)
  end

  defp match(value, query, "MAC") do
    match(value, query, nil) || match(compact_mac(value), compact_mac(query), nil)
  end

  defp match(value, query, _field) do
    candidate = normalize(value)

    cond do
      query == "" -> nil
      candidate == query -> :exact
      String.starts_with?(candidate, query) -> :prefix
      String.contains?(candidate, query) -> :contains
      true -> nil
    end
  end

  defp discovered_devices(correlation),
    do: correlation.out_of_dhcp_devices ++ correlation.unknown_devices

  defp compact_mac(value),
    do:
      value
      |> String.downcase()
      |> String.replace(@mac_separators, "")

  defp normalize(value) when is_binary(value),
    do:
      value
      |> String.trim()
      |> String.downcase()

  defp normalize(_value), do: ""
end
