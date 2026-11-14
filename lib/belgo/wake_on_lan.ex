defmodule Belgo.WakeOnLan do
  @moduledoc """
  Wakes devices up with a magic packet, then watches them (`Belgo.WakeOnLan.Watch`)
  until they answer pings or `wake_on_lan.timeout` of `config.yaml` elapses. The
  outcome is broadcast as `{:wake_on_lan, Outcome.t()}` on `topic/0`.

  How the packet leaves (`method/1`): a provider supporting wake-on-LAN (OPNsense
  and its `os-wol` plugin) sends it when `providers.yaml` configures one, and its
  `wake_on_lan` option can turn the feature off; without such a provider, Belgo
  broadcasts the packet itself (`Belgo.WakeOnLan.Sender`, same layer 2 network only).

  The sender and the ping function are configurable (`config :belgo,
  Belgo.WakeOnLan, send: …, ping: …`) so tests never touch the network.
  """

  alias Belgo.Config
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Interface
  alias Belgo.Inventory.Network
  alias Belgo.Network.Cidr
  alias Belgo.Network.IpAddress
  alias Belgo.Providers.Settings
  alias Belgo.Providers.Settings.Configured
  alias Belgo.Reachability
  alias Belgo.Reachability.Pinger
  alias Belgo.WakeOnLan.MagicPacket
  alias Belgo.WakeOnLan.Sender
  alias Belgo.WakeOnLan.Watch

  require Logger

  @topic "wake_on_lan"
  @limited_broadcast_address "255.255.255.255"

  @type wake_result ::
          {:ok, :watching | :already_watching | :not_watched}
          | {:error, :invalid_mac | :disabled | :no_address | term()}

  @typedoc "How magic packets are sent."
  @type method :: :broadcast | {:provider, Configured.t()} | :disabled

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
  @spec wake(Device.t(), Interface.t(), [Network.t()], method()) :: wake_result()
  def wake(%Device{} = device, %Interface{} = interface, networks, method \\ method()) do
    environment = Application.get_env(:belgo, __MODULE__, [])

    with {:ok, packet} <- build_packet(interface.mac),
         :ok <- send_packet(method, packet, interface, networks, environment) do
      watch(device, environment)
    end
  end

  @doc """
  How magic packets are sent, from `providers.yaml` (re-read on each call): the first
  provider supporting wake-on-LAN, `:disabled` when its configuration turns it off,
  `:broadcast` without such a provider (or with an invalid file).

  Options: `:directory` and `:environment`, defaulting to the discovery's.
  """
  @spec method(Keyword.t()) :: method()
  def method(options \\ []) do
    case Settings.current(options) do
      {:ok, settings} -> settings_method(settings)
      {:error, _messages} -> :broadcast
    end
  end

  @doc "Returns `true` unless the provider configuration turns wake-on-LAN off."
  @spec enabled?(Keyword.t()) :: boolean()
  def enabled?(options \\ []), do: method(options) != :disabled

  defp settings_method(%Settings{configs: configs}) do
    case Enum.find(configs, &wakes?(&1.module)) do
      nil ->
        :broadcast

      %Configured{module: module, config: config} = configured ->
        if module.wake_on_lan?(config), do: {:provider, configured}, else: :disabled
    end
  end

  defp wakes?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :wake, 3)

  defp send_packet(:disabled, _packet, _interface, _networks, _environment),
    do: {:error, :disabled}

  defp send_packet(:broadcast, packet, interface, networks, environment) do
    send_packet = Keyword.get(environment, :send, &Sender.send_packet/2)
    send_packet.(packet, broadcast_addresses(interface, networks))
  end

  defp send_packet({:provider, configured}, _packet, interface, networks, _environment) do
    %Configured{module: module, config: config} = configured
    log_prefix = "[wake_on_lan] [#{module.key()}] [#{interface.mac}]"

    with {:ok, address} <- target_address(interface, networks),
         :ok <- module.wake(config, interface.mac, address) do
      Logger.info("#{log_prefix} magic packet sent on the network of #{address}")
    else
      {:error, reason} = error ->
        Logger.error("#{log_prefix} failed: #{inspect(reason)}")
        error
    end
  end

  # An address of the interface network: its IP, else its declared network.
  defp target_address(%Interface{ip: ip}, _networks) when is_binary(ip), do: {:ok, ip}

  defp target_address(%Interface{network_id: network_id}, networks) do
    with %Network{cidr: cidr} <- Enum.find(networks, &(&1.id == network_id)),
         {:ok, parsed} <- Cidr.parse(cidr) do
      {:ok, IpAddress.format(parsed.address)}
    else
      _missing -> {:error, :no_address}
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
