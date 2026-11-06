defmodule Belgo.Inventory.Network do
  @moduledoc """
  An IP network (subnet / VLAN) devices get their addresses from.

  `dhcp_start` / `dhcp_end` delimit the dynamic DHCP pool, when known: addresses
  outside of it are static or reserved. `ranges` are logical ranges
  (`Belgo.Inventory.AddressRange`): names for parts of the network, optionally tied
  to a device kind to suggest addresses. They must belong to the network and not
  overlap.
  """

  use Belgo, :schema

  alias Belgo.Inventory.AddressRange
  alias Belgo.Inventory.Identifier
  alias Belgo.Inventory.SortParams
  alias Belgo.Inventory.Types
  alias Belgo.Network.Cidr
  alias Belgo.Network.IpAddress

  @fields ~w(id name cidr vlan gateway domain dhcp_start dhcp_end notes)a
  @required ~w(id name cidr)a
  @minimum_vlan 1
  @maximum_vlan 4094
  @domain_format ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\z/

  embedded_schema do
    field(:name, :string)
    field(:cidr, Types.Cidr)
    field(:vlan, :integer)
    field(:gateway, Types.IpAddress)
    field(:domain, :string)
    field(:dhcp_start, Types.IpAddress)
    field(:dhcp_end, Types.IpAddress)
    field(:notes, :string)
    embeds_many(:ranges, AddressRange, on_replace: :delete)
  end

  @doc "Builds a changeset validating the network on its own."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(network, params) do
    params = SortParams.new_last(params, ["ranges_sort"])

    network
    |> cast(params, @fields)
    |> cast_embed(:ranges, sort_param: :ranges_sort, drop_param: :ranges_drop)
    |> Identifier.put_default(:name)
    |> validate_required(@required)
    |> Identifier.validate(:id)
    |> validate_number(:vlan,
      greater_than_or_equal_to: @minimum_vlan,
      less_than_or_equal_to: @maximum_vlan
    )
    |> update_change(:domain, &String.downcase/1)
    |> validate_format(:domain, @domain_format, message: "must be a valid domain name")
    |> validate_gateway_in_range()
    |> validate_dhcp_range()
    |> validate_ranges()
  end

  @doc "Returns `true` when the address (string) belongs to the network range."
  @spec contains?(t(), String.t()) :: boolean()
  def contains?(%__MODULE__{cidr: cidr}, address) do
    with {:ok, range} <- Cidr.parse(cidr),
         {:ok, parsed_address} <- IpAddress.parse(address) do
      Cidr.contains?(range, parsed_address)
    else
      _ -> false
    end
  end

  @doc "Returns `true` when the network declares its dynamic DHCP pool."
  @spec dhcp_range?(t()) :: boolean()
  def dhcp_range?(%__MODULE__{dhcp_start: dhcp_start, dhcp_end: dhcp_end}),
    do: is_binary(dhcp_start) and is_binary(dhcp_end)

  @doc """
  Returns `true` when the address (string) is in the dynamic DHCP pool. Always
  `false` when the network does not declare its pool.
  """
  @spec in_dhcp_range?(t(), String.t()) :: boolean()
  def in_dhcp_range?(%__MODULE__{} = network, address) do
    with true <- dhcp_range?(network),
         {:ok, first} <- IpAddress.parse(network.dhcp_start),
         {:ok, last} <- IpAddress.parse(network.dhcp_end),
         {:ok, parsed} <- IpAddress.parse(address) do
      IpAddress.sort_key(first) <= IpAddress.sort_key(parsed) and
        IpAddress.sort_key(parsed) <= IpAddress.sort_key(last)
    else
      _ -> false
    end
  end

  defp validate_dhcp_range(changeset) do
    case {get_field(changeset, :dhcp_start), get_field(changeset, :dhcp_end)} do
      {nil, nil} ->
        changeset

      {nil, _dhcp_end} ->
        add_error(changeset, :dhcp_start, "is required with the end of the range")

      {_dhcp_start, nil} ->
        add_error(changeset, :dhcp_end, "is required with the start of the range")

      {dhcp_start, dhcp_end} ->
        validate_dhcp_bounds(changeset, dhcp_start, dhcp_end)
    end
  end

  defp validate_dhcp_bounds(changeset, dhcp_start, dhcp_end) do
    cidr = get_field(changeset, :cidr)

    cond do
      cidr && not contains?(%__MODULE__{cidr: cidr}, dhcp_start) ->
        add_error(changeset, :dhcp_start, "must belong to %{cidr}", cidr: cidr)

      cidr && not contains?(%__MODULE__{cidr: cidr}, dhcp_end) ->
        add_error(changeset, :dhcp_end, "must belong to %{cidr}", cidr: cidr)

      IpAddress.sort_key(dhcp_start) > IpAddress.sort_key(dhcp_end) ->
        add_error(changeset, :dhcp_end, "must come after the start of the range")

      true ->
        changeset
    end
  end

  defp validate_ranges(changeset) do
    cidr = get_field(changeset, :cidr)
    ranges = Enum.filter(get_field(changeset, :ranges), &(&1.start && &1.end))

    outside =
      for range <- ranges,
          cidr,
          not (contains?(%__MODULE__{cidr: cidr}, range.start) and
                 contains?(%__MODULE__{cidr: cidr}, range.end)),
          do: "#{range.name} must belong to #{cidr}"

    overlapping =
      for {left_range, position} <- Enum.with_index(ranges),
          right_range <- Enum.drop(ranges, position + 1),
          AddressRange.overlap?(left_range, right_range),
          do: "#{left_range.name} and #{right_range.name} overlap"

    Enum.reduce(outside ++ overlapping, changeset, &add_error(&2, :ranges, &1))
  end

  defp validate_gateway_in_range(changeset) do
    gateway = get_field(changeset, :gateway)
    cidr = get_field(changeset, :cidr)

    if gateway && cidr && not contains?(%__MODULE__{cidr: cidr}, gateway) do
      add_error(changeset, :gateway, "must belong to %{cidr}", cidr: cidr)
    else
      changeset
    end
  end
end
