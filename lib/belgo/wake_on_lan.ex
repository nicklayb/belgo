defmodule Belgo.WakeOnLan do
  @moduledoc """
  Wakes devices up with a magic packet, then watches them (`Belgo.WakeOnLan.Watch`)
  until they answer pings or `wake_on_lan.timeout` of `config.yaml` elapses. The
  outcome is broadcast as `{:wake_on_lan, Outcome.t()}` on `topic/0`.

  The sender and the ping function are configurable (`config :belgo,
  Belgo.WakeOnLan, send: …, ping: …`) so tests never touch the network.
  """

  alias Belgo.Config
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Interface
  alias Belgo.Inventory.Network
  alias Belgo.Network.Cidr
  alias Belgo.Network.IpAddress
  alias Belgo.Reachability
  alias Belgo.Reachability.Pinger
  alias Belgo.WakeOnLan.MagicPacket
  alias Belgo.WakeOnLan.Sender
  alias Belgo.WakeOnLan.Watch

  @topic "wake_on_lan"
  @limited_broadcast_address "255.255.255.255"

  @type wake_result ::
          {:ok, :watching | :already_watching | :not_watched}
          | {:error, :invalid_mac | term()}

  @doc "PubSub topic receiving `{:wake_on_lan, Outcome.t()}` messages."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the calling process to wake-on-LAN outcomes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Belgo.PubSub, @topic)

  @doc """
  Sends the magic packet to an interface of the device, then watches the device
  (`:not_watched` when it has no address to ping, `:already_watching` when a watch
  runs already: the packet is sent again, the watch goes on).
  """
  @spec wake(Device.t(), Interface.t(), [Network.t()]) :: wake_result()
  def wake(%Device{} = device, %Interface{} = interface, networks) do
    environment = Application.get_env(:belgo, __MODULE__, [])
    send_packet = Keyword.get(environment, :send, &Sender.send_packet/2)

    with {:ok, packet} <- build_packet(interface.mac),
         :ok <- send_packet.(packet, broadcast_addresses(interface, networks)) do
      watch(device, environment)
    end
  end

  @doc """
  Where the packet goes: the limited broadcast address, and the broadcast address of
  the interface network (directed broadcast, when routers forward it).
  """
  @spec broadcast_addresses(Interface.t(), [Network.t()]) :: [String.t()]
  def broadcast_addresses(%Interface{} = interface, networks) do
    directed =
      for network <- networks,
          network.id == interface.network_id or
            (interface.ip != nil and Network.contains?(network, interface.ip)),
          {:ok, cidr} <- [Cidr.parse(network.cidr)],
          IpAddress.ipv4?(cidr.address),
          do: IpAddress.format(Cidr.last_address(cidr))

    Enum.uniq([@limited_broadcast_address | directed])
  end

  defp build_packet(nil), do: {:error, :invalid_mac}

  defp build_packet(mac) do
    case MagicPacket.build(mac) do
      {:ok, packet} -> {:ok, packet}
      :error -> {:error, :invalid_mac}
    end
  end

  defp watch(device, environment) do
    case Device.ip_addresses(device) do
      [] -> {:ok, :not_watched}
      _addresses -> start_watch(device, environment)
    end
  end

  defp start_watch(device, environment) do
    config = Config.current()

    options = [
      device: device,
      ping_interval: config.wake_on_lan.ping_interval,
      timeout: config.wake_on_lan.timeout,
      ping_timeout: config.ping.timeout,
      ping: Keyword.get(environment, :ping, &Pinger.ping/2),
      pubsub: Belgo.PubSub,
      topic: @topic,
      registry: Belgo.WakeOnLan.Registry,
      on_awake: &Reachability.check(&1, force: true)
    ]

    case DynamicSupervisor.start_child(Belgo.WakeOnLan.Supervisor, {Watch, options}) do
      {:ok, _pid} -> {:ok, :watching}
      {:error, {:already_started, _pid}} -> {:ok, :already_watching}
      {:error, reason} -> {:error, reason}
    end
  end
end
