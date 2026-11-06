defmodule Belgo.Network.IpAddress do
  @moduledoc "Parsing and arithmetic helpers for IPv4 and IPv6 addresses."

  import Bitwise

  @type t :: :inet.ip_address()

  @ipv4_tuple_size 4
  @ipv4_bit_size 32
  @ipv6_bit_size 128
  @ipv4_segment_bit_size 8
  @ipv6_segment_bit_size 16
  @unsortable_key {@ipv6_bit_size + 1, 0}

  @doc "Parses a string into an address tuple."
  @spec parse(any()) :: {:ok, t()} | :error
  def parse(value) when is_binary(value) do
    case value
         |> String.trim()
         |> String.to_charlist()
         |> :inet.parse_strict_address() do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  def parse(_value), do: :error

  @doc "Formats an address tuple into its canonical string representation."
  @spec format(t()) :: String.t()
  def format(address) do
    address
    |> :inet.ntoa()
    |> List.to_string()
  end

  @doc "Returns `true` when the address is IPv4."
  @spec ipv4?(t()) :: boolean()
  def ipv4?(address), do: tuple_size(address) == @ipv4_tuple_size

  @doc "Returns the number of bits of the address family."
  @spec family_bit_size(t()) :: pos_integer()
  def family_bit_size(address) do
    if ipv4?(address), do: @ipv4_bit_size, else: @ipv6_bit_size
  end

  @doc "Converts an address tuple to its integer value."
  @spec to_integer(t()) :: non_neg_integer()
  def to_integer(address) do
    segment_bit_size = segment_bit_size(address)

    address
    |> Tuple.to_list()
    |> Enum.reduce(0, fn segment, accumulator -> (accumulator <<< segment_bit_size) + segment end)
  end

  @doc "Converts an integer back to an address tuple of the same family as `reference`."
  @spec from_integer(non_neg_integer(), t()) :: t()
  def from_integer(value, reference) do
    segment_bit_size = segment_bit_size(reference)
    segment_mask = (1 <<< segment_bit_size) - 1

    0..(tuple_size(reference) - 1)
    |> Enum.map(fn position ->
      shift = (tuple_size(reference) - 1 - position) * segment_bit_size
      value >>> shift &&& segment_mask
    end)
    |> List.to_tuple()
  end

  @doc "Sort key ordering IPv4 before IPv6, then numerically. Accepts strings or tuples."
  @spec sort_key(String.t() | t() | nil) :: {non_neg_integer(), non_neg_integer()}
  def sort_key(address) when is_binary(address) do
    case parse(address) do
      {:ok, parsed} -> sort_key(parsed)
      :error -> @unsortable_key
    end
  end

  def sort_key(nil), do: @unsortable_key

  def sort_key(address) when is_tuple(address),
    do: {family_bit_size(address), to_integer(address)}

  defp segment_bit_size(address) do
    if ipv4?(address), do: @ipv4_segment_bit_size, else: @ipv6_segment_bit_size
  end
end
