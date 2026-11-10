defmodule Belgo.Providers.Opnsense.Push do
  @moduledoc """
  Plans the OPNsense writes needed for a desired state. Pure functions only.

  Kea reservations are matched by MAC address, Unbound host overrides by host and
  domain. Following `Belgo.Sync.Plan`, missing entries are created and differing
  ones updated; pushes never delete. The only deletion is `plan_kea_release/2`: the
  Kea reservations of MAC addresses removed from the inventory (deleted device or
  interface, changed MAC). A name Unbound already holds several times is
  left untouched and reported, so pushes never make duplicates worse. Updates only send the managed fields, which
  OPNsense applies as a partial update. Reservations manage their IP, hostname,
  description (`Device.interface_label/2`, e.g. `Skynet (enp4s0)`) and subnet.
  """

  alias Belgo.Network.Cidr
  alias Belgo.Network.IpAddress
  alias Belgo.Network.MacAddress
  alias Belgo.Providers.Opnsense.Translate
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.Plan

  @add_reservation_path "/api/kea/dhcpv4/add_reservation"
  @set_reservation_path "/api/kea/dhcpv4/set_reservation/"
  @delete_reservation_path "/api/kea/dhcpv4/del_reservation/"
  @add_host_override_path "/api/unbound/settings/add_host_override"
  @set_host_override_path "/api/unbound/settings/set_host_override/"
  @managed_reservation_fields [:ip, :hostname, :description, :subnet]

  defmodule Operation do
    @moduledoc "One write to OPNsense."
    @enforce_keys [:service, :action, :path, :body, :summary]
    defstruct [:service, :action, :path, :body, :summary]

    @type t :: %__MODULE__{
            service: :kea | :unbound,
            action: :create | :update | :delete,
            path: String.t(),
            body: map(),
            summary: String.t()
          }
  end

  @type plan :: %{operations: [Operation.t()], skipped: [String.t()]}

  @doc "Plans the Kea reservations from the Kea `subnets` and `reservations` rows."
  @spec plan_kea(DesiredState.t(), %{subnets: [map()], reservations: [map()]}) :: plan()
  def plan_kea(%DesiredState{} = desired_state, rows) do
    {operations, skipped} = reservation_operations(desired_state, rows)
    %{operations: operations, skipped: skipped}
  end

  @doc """
  Plans the deletion of the Kea reservations held by `mac_addresses` (MAC addresses
  the inventory no longer has) from the Kea `reservations` rows.
  """
  @spec plan_kea_release([String.t()], %{reservations: [map()]}) :: plan()
  def plan_kea_release(mac_addresses, rows) do
    released = MapSet.new(mac_addresses, &normalize_mac/1)

    operations =
      rows.reservations
      |> Enum.flat_map(&actual_reservation/1)
      |> Enum.filter(&MapSet.member?(released, &1.mac))
      |> Enum.sort_by(&{&1.mac, &1.ip})
      |> Enum.map(&release_operation/1)

    %{operations: operations, skipped: []}
  end

  @doc "Plans the Unbound host overrides from the `host_overrides` rows."
  @spec plan_unbound(DesiredState.t(), %{host_overrides: [map()]}) :: plan()
  def plan_unbound(%DesiredState{} = desired_state, rows) do
    {operations, skipped} = host_override_operations(desired_state, rows)
    %{operations: operations, skipped: skipped}
  end

  @doc "Returns `true` when the desired state has Kea reservations to write."
  @spec kea_needed?(DesiredState.t()) :: boolean()
  def kea_needed?(%DesiredState{dhcp_reservations: reservations}), do: reservations != []

  @doc "Returns `true` when the desired state has names Unbound can hold (with a domain)."
  @spec unbound_needed?(DesiredState.t()) :: boolean()
  def unbound_needed?(%DesiredState{dns_records: records}), do: Enum.any?(records, & &1.domain)

  defp reservation_operations(desired_state, rows) do
    subnet_uuid_by_cidr = Map.new(rows.subnets, &{normalize_cidr(&1["subnet"]), &1["uuid"]})

    {desired, skipped} =
      Enum.reduce(desired_state.dhcp_reservations, {[], []}, fn reservation, {desired, skipped} ->
        case Map.fetch(subnet_uuid_by_cidr, reservation.cidr) do
          {:ok, subnet} ->
            entry = %{
              mac: reservation.mac,
              ip: reservation.address,
              hostname: reservation.hostname,
              description: reservation.description,
              subnet: subnet
            }

            {[entry | desired], skipped}

          :error ->
            {desired,
             [
               "reservation of #{reservation.mac}: no Kea subnet for #{reservation.cidr || "its network"}"
               | skipped
             ]}
        end
      end)

    actual = Enum.flat_map(rows.reservations, &actual_reservation/1)

    operations =
      desired
      |> Plan.build(actual,
        key: & &1.mac,
        comparable: &Map.take(&1, @managed_reservation_fields)
      )
      |> Enum.map(&reservation_operation/1)

    {operations, Enum.reverse(skipped)}
  end

  defp actual_reservation(row) do
    case MacAddress.normalize(row["hw_address"]) do
      {:ok, mac} ->
        [
          %{
            uuid: row["uuid"],
            mac: mac,
            ip: normalize_ip(row["ip_address"]),
            hostname: blank_to_nil(row["hostname"]),
            description: blank_description(row["description"]),
            subnet: row["subnet"]
          }
        ]

      :error ->
        []
    end
  end

  defp reservation_operation(%Plan.Change{action: :create, desired: desired}) do
    %Operation{
      service: :kea,
      action: :create,
      path: @add_reservation_path,
      body: %{
        "reservation" => %{
          "subnet" => desired.subnet,
          "hw_address" => desired.mac,
          "ip_address" => desired.ip,
          "hostname" => desired.hostname || "",
          "description" => desired.description
        }
      },
      summary:
        "create reservation #{desired.mac} → #{desired.ip} (#{desired.hostname}, #{desired.description})"
    }
  end

  defp reservation_operation(%Plan.Change{action: :update, desired: desired, actual: actual}) do
    %Operation{
      service: :kea,
      action: :update,
      path: @set_reservation_path <> actual.uuid,
      body: %{
        "reservation" => %{
          "subnet" => desired.subnet,
          "ip_address" => desired.ip,
          "hostname" => desired.hostname || "",
          "description" => desired.description
        }
      },
      summary: "update reservation #{desired.mac}: #{reservation_changes(actual, desired)}"
    }
  end

  defp release_operation(actual) do
    %Operation{
      service: :kea,
      action: :delete,
      path: @delete_reservation_path <> actual.uuid,
      body: %{},
      summary: "delete reservation #{actual.mac} → #{actual.ip} (#{actual.hostname})"
    }
  end

  defp reservation_changes(actual, desired) do
    @managed_reservation_fields
    |> Enum.reject(&(Map.fetch!(actual, &1) == Map.fetch!(desired, &1)))
    |> Enum.map_join("; ", fn
      :subnet ->
        "Kea subnet changed"

      field ->
        "#{field} #{format_value(Map.fetch!(actual, field))} → #{format_value(Map.fetch!(desired, field))}"
    end)
  end

  defp format_value(nil), do: "none"
  defp format_value(""), do: "none"
  defp format_value(value), do: value

  defp host_override_operations(desired_state, rows) do
    {desired, skipped} =
      Enum.reduce(desired_state.dns_records, {[], []}, fn
        %{domain: nil} = record, {desired, skipped} ->
          {desired, ["#{record.name}: no domain, Unbound host overrides need one" | skipped]}

        record, {desired, skipped} ->
          {[
             %{
               host: record.host,
               domain: record.domain,
               ip: record.address,
               description: record.description
             }
             | desired
           ], skipped}
      end)

    alias_names = MapSet.new(Enum.flat_map(rows.host_overrides, &alias_keys/1))

    {aliased, desired} =
      Enum.split_with(desired, &MapSet.member?(alias_names, {&1.host, &1.domain}))

    alias_skips =
      Enum.map(aliased, &"#{&1.host}.#{&1.domain}: already an Unbound alias, left untouched")

    actual = Enum.flat_map(rows.host_overrides, &actual_host_override/1)

    duplicated =
      actual
      |> Enum.frequencies_by(&{&1.host, &1.domain})
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> Map.new()

    {duplicates, desired} =
      Enum.split_with(desired, &Map.has_key?(duplicated, {&1.host, &1.domain}))

    duplicate_skips =
      Enum.map(duplicates, fn record ->
        count = Map.fetch!(duplicated, {record.host, record.domain})

        "#{record.host}.#{record.domain}: #{count} host overrides in Unbound, left untouched until fixed in OPNsense"
      end)

    operations =
      desired
      |> Enum.uniq_by(&{&1.host, &1.domain})
      |> Plan.build(actual, key: &{&1.host, &1.domain}, comparable: & &1.ip)
      |> Enum.map(&host_override_operation/1)

    {operations, Enum.reverse(skipped) ++ alias_skips ++ Enum.uniq(duplicate_skips)}
  end

  defp actual_host_override(row) do
    if Translate.address_record?(row), do: [actual_address_record(row)], else: []
  end

  defp actual_address_record(row) do
    %{
      uuid: row["uuid"],
      host: downcase(row["hostname"]),
      domain: downcase(row["domain"]),
      ip: normalize_ip(row["server"])
    }
  end

  defp alias_keys(%{"_children" => children}) when is_list(children) do
    for %{"hostname" => host, "domain" => domain} <- children,
        do: {downcase(host), downcase(domain)}
  end

  defp alias_keys(_row), do: []

  defp host_override_operation(%Plan.Change{action: :create, desired: desired}) do
    %Operation{
      service: :unbound,
      action: :create,
      path: @add_host_override_path,
      body: %{
        "host" => %{
          "enabled" => "1",
          "hostname" => desired.host,
          "domain" => desired.domain,
          "rr" => record_type(desired.ip),
          "server" => desired.ip,
          "description" => desired.description
        }
      },
      summary: "create host override #{desired.host}.#{desired.domain} → #{desired.ip}"
    }
  end

  defp host_override_operation(%Plan.Change{action: :update, desired: desired, actual: actual}) do
    %Operation{
      service: :unbound,
      action: :update,
      path: @set_host_override_path <> actual.uuid,
      body: %{"host" => %{"rr" => record_type(desired.ip), "server" => desired.ip}},
      summary:
        "update host override #{desired.host}.#{desired.domain}: #{actual.ip} → #{desired.ip}"
    }
  end

  defp record_type(ip) do
    {:ok, address} = IpAddress.parse(ip)
    if IpAddress.ipv4?(address), do: "A", else: "AAAA"
  end

  defp normalize_cidr(value) do
    case Cidr.parse(value) do
      {:ok, cidr} -> Cidr.format(cidr)
      :error -> nil
    end
  end

  defp normalize_mac(value) do
    case MacAddress.normalize(value) do
      {:ok, mac} -> mac
      :error -> value
    end
  end

  defp normalize_ip(value) do
    case IpAddress.parse(value) do
      {:ok, address} -> IpAddress.format(address)
      :error -> nil
    end
  end

  defp blank_description(value) when is_binary(value), do: value
  defp blank_description(_value), do: ""

  defp blank_to_nil(value) when is_binary(value) and value != "", do: String.downcase(value)
  defp blank_to_nil(_value), do: nil

  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(_value), do: nil
end
