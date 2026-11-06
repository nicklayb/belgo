defmodule Belgo.Providers.Opnsense.Translate do
  @moduledoc "Turns OPNsense API rows into observations. Pure functions only."

  alias Belgo.Discovery.Observation
  alias Belgo.Network.Cidr
  alias Belgo.Network.IpAddress
  alias Belgo.Network.MacAddress

  @provider :opnsense
  @address_record_types ["A", "AAAA"]

  @doc """
  Kea subnets become network observations. The first pool (`start - end`) gives the
  DHCP range; the exact `pools` format is parsed defensively (lines or commas).
  """
  @spec subnets([map()]) :: [Observation.t()]
  def subnets(rows) do
    Enum.flat_map(rows, fn row ->
      case normalize_cidr(row["subnet"]) do
        nil ->
          []

        cidr ->
          [
            %Observation{
              provider: @provider,
              source: :kea_subnet,
              kind: :network,
              reference: row["uuid"],
              cidr: cidr,
              gateway:
                row
                |> option_data("routers")
                |> first_address(),
              dhcp_start: elem(first_pool(row), 0),
              dhcp_end: elem(first_pool(row), 1),
              domain:
                row
                |> option_data("domain_name")
                |> blank_to_nil(),
              description: blank_to_nil(row["description"])
            }
          ]
      end
    end)
  end

  @doc """
  OPNsense itself, as the gateway: the router address of every Kea subnet, linked by
  a common identity so they make a single device.
  """
  @spec gateway([map()]) :: [Observation.t()]
  def gateway(subnet_rows) do
    subnet_rows
    |> Enum.map(
      &(&1
        |> option_data("routers")
        |> first_address())
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(fn address ->
      %Observation{
        provider: @provider,
        source: :opnsense_gateway,
        kind: :device,
        reference: address,
        identity: "opnsense-gateway",
        role: :gateway,
        ip: address,
        description: "OPNsense"
      }
    end)
  end

  @doc """
  Kea reservations become device observations. The `subnet` of a row may be the
  subnet uuid or its CIDR, both are resolved against the subnet rows.
  """
  @spec reservations([map()], [map()]) :: [Observation.t()]
  def reservations(rows, subnet_rows) do
    cidr_by_uuid = Map.new(subnet_rows, &{&1["uuid"], normalize_cidr(&1["subnet"])})

    Enum.map(rows, fn row ->
      %Observation{
        provider: @provider,
        source: :kea_reservation,
        kind: :device,
        reference: row["uuid"],
        mac: normalize_mac(row["hw_address"]),
        ip: normalize_ip(row["ip_address"]),
        hostname:
          row["hostname"]
          |> blank_to_nil()
          |> downcase(),
        cidr: Map.get(cidr_by_uuid, row["subnet"]) || normalize_cidr(row["subnet"]),
        description: blank_to_nil(row["description"])
      }
    end)
  end

  @doc """
  Whether an Unbound host override row is an address record (A / AAAA). Search rows
  give `rr` as its label, `A (IPv4 address)` (measured on the owner's OPNsense), or
  as the raw value `A`: only the first word counts. A missing `rr` is an address.
  """
  @spec address_record?(map()) :: boolean()
  def address_record?(%{"rr" => record_type}) when is_binary(record_type) do
    record_type
    |> String.split(" ", parts: 2)
    |> List.first()
    |> String.upcase()
    |> Kernel.in(@address_record_types)
  end

  def address_record?(%{"rr" => nil}), do: true
  def address_record?(%{"rr" => _record_type}), do: false
  def address_record?(_row), do: true

  @doc "Unbound A / AAAA host overrides become device observations."
  @spec host_overrides([map()]) :: [Observation.t()]
  def host_overrides(rows) do
    rows
    |> Enum.filter(&(address_record?(&1) and normalize_ip(&1["server"]) != nil))
    |> Enum.map(fn row ->
      %Observation{
        provider: @provider,
        source: :unbound_host_override,
        kind: :device,
        reference: row["uuid"],
        ip: normalize_ip(row["server"]),
        hostname:
          row["hostname"]
          |> blank_to_nil()
          |> downcase(),
        domain:
          row["domain"]
          |> blank_to_nil()
          |> downcase(),
        description: blank_to_nil(row["description"])
      }
    end)
  end

  defp option_data(row, field) do
    case row do
      %{"option_data" => %{^field => value}} -> value
      %{^field => value} -> value
      _missing -> nil
    end
  end

  defp first_pool(row) do
    row
    |> Map.get("pools")
    |> pool_lines()
    |> Enum.find_value({nil, nil}, &parse_pool/1)
  end

  defp pool_lines(pools) when is_binary(pools),
    do: String.split(pools, ["\n", ",", ";"], trim: true)

  defp pool_lines(_pools), do: []

  defp parse_pool(line) do
    case String.split(line, "-", parts: 2) do
      [first, last] ->
        with first when first != nil <- normalize_ip(first),
             last when last != nil <- normalize_ip(last) do
          {first, last}
        end

      _not_a_range ->
        nil
    end
  end

  defp first_address(nil), do: nil

  defp first_address(value) when is_binary(value) do
    value
    |> String.split(",")
    |> List.first()
    |> normalize_ip()
  end

  defp first_address(_value), do: nil

  defp normalize_cidr(value) do
    case Cidr.parse(value) do
      {:ok, cidr} -> Cidr.format(cidr)
      :error -> nil
    end
  end

  defp normalize_ip(value) do
    case IpAddress.parse(value) do
      {:ok, address} -> IpAddress.format(address)
      :error -> nil
    end
  end

  defp normalize_mac(value) do
    case MacAddress.normalize(value) do
      {:ok, mac} -> mac
      :error -> nil
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp downcase(nil), do: nil
  defp downcase(value), do: String.downcase(value)
end
