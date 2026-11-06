defmodule Belgo.WakeOnLan.MagicPacket do
  @moduledoc """
  The wake-on-LAN magic packet: 6 bytes `0xFF` followed by the target MAC address
  repeated 16 times, sent over UDP (port 9, the discard port, by convention).
  """

  alias Belgo.Network.MacAddress

  @synchronisation_stream :binary.copy(<<0xFF>>, 6)
  @mac_repetitions 16

  @doc "Builds the packet waking the machine with this MAC address."
  @spec build(String.t()) :: {:ok, binary()} | :error
  def build(mac) do
    with {:ok, normalized} <- MacAddress.normalize(mac) do
      mac_bytes = Base.decode16!(String.replace(normalized, ":", ""), case: :lower)
      {:ok, @synchronisation_stream <> :binary.copy(mac_bytes, @mac_repetitions)}
    end
  end
end
