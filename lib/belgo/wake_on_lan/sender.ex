defmodule Belgo.WakeOnLan.Sender do
  @moduledoc """
  Sends magic packets as UDP broadcasts. Broadcasts stay on the local network: Belgo
  must be on the same layer 2 network as the device (a container needs host
  networking), or the router must forward directed broadcasts.
  """

  @port 9

  @doc "Sends the packet to each broadcast address (`255.255.255.255`, `10.0.0.255`…)."
  @spec send_packet(binary(), [String.t()]) :: :ok | {:error, term()}
  def send_packet(packet, broadcast_addresses) do
    with {:ok, socket} <- :gen_udp.open(0, [:binary, broadcast: true]) do
      results =
        for address <- broadcast_addresses do
          :gen_udp.send(socket, String.to_charlist(address), @port, packet)
        end

      :gen_udp.close(socket)

      # One reachable broadcast address is enough.
      if Enum.any?(results, &(&1 == :ok)),
        do: :ok,
        else: Enum.find(results, &match?({:error, _reason}, &1))
    end
  end
end
