defmodule Belgo.Network.Cidr do
  @moduledoc "A network range expressed in CIDR notation (`192.168.1.0/24`)."

  import Bitwise

  alias Belgo.Network.Cidr
  alias Belgo.Network.IpAddress

  @enforce_keys [:address, :prefix_length]
  defstruct [:address, :prefix_length]

  @type t :: %Cidr{address: IpAddress.t(), prefix_length: non_neg_integer()}

  @doc "Parses a CIDR string. Host bits are cleared so the address is the network address."
  @spec parse(any()) :: {:ok, t()} | :error
  def parse(value) when is_binary(value) do
    with [address_part, prefix_part] <- String.split(String.trim(value), "/"),
         {:ok, address} <- IpAddress.parse(address_part),
         {prefix_length, ""} <- Integer.parse(prefix_part),
         true <- prefix_length in 0..IpAddress.family_bit_size(address) do
      {:ok, %Cidr{address: network_address(address, prefix_length), prefix_length: prefix_length}}
    else
      _ -> :error
    end
  end

  def parse(_value), do: :error

  @doc "Formats a CIDR struct back to its string notation."
  @spec format(t()) :: String.t()
  def format(%Cidr{address: address, prefix_length: prefix_length}) do
    "#{IpAddress.format(address)}/#{prefix_length}"
  end

  @doc "Returns `true` when the address belongs to the range."
  @spec contains?(t(), IpAddress.t()) :: boolean()
  def contains?(%Cidr{address: network, prefix_length: prefix_length}, address) do
    IpAddress.family_bit_size(network) == IpAddress.family_bit_size(address) and
      network_address(address, prefix_length) == network
  end

  @doc "Returns the number of addresses in the range."
  @spec size(t()) :: pos_integer()
  def size(%Cidr{address: address, prefix_length: prefix_length}) do
    1 <<< (IpAddress.family_bit_size(address) - prefix_length)
  end

  defp network_address(address, prefix_length) do
    host_bit_size = IpAddress.family_bit_size(address) - prefix_length

    address
    |> IpAddress.to_integer()
    |> Bitwise.>>>(host_bit_size)
    |> Bitwise.<<<(host_bit_size)
    |> IpAddress.from_integer(address)
  end
end
