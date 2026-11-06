defmodule Belgo.Fixtures.WakeOnLan do
  @moduledoc "Wake-on-LAN without network: packets are broadcast on a PubSub topic instead."

  @topic "test:wake_on_lan_packets"

  @doc "Topic receiving `{:magic_packet, packet, broadcast_addresses}`."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Records the packet like `Belgo.WakeOnLan.Sender.send_packet/2` would send it."
  @spec send_packet(binary(), [String.t()]) :: :ok
  def send_packet(packet, broadcast_addresses) do
    Phoenix.PubSub.broadcast(
      Belgo.PubSub,
      @topic,
      {:magic_packet, packet, broadcast_addresses}
    )
  end
end
