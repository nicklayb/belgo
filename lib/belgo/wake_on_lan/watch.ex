defmodule Belgo.WakeOnLan.Watch do
  @moduledoc """
  Pings a woken device every `ping_interval` until one of its addresses answers or
  `timeout` elapses, then broadcasts `{:wake_on_lan, Outcome.t()}` on
  `Belgo.WakeOnLan.topic/0` and stops. One watch per device (registered by device id
  in `Belgo.WakeOnLan.Registry`), started under `Belgo.WakeOnLan.Supervisor`.

  Options: `:device` (required), `:ping_interval`, `:ping_timeout`, `:timeout`
  (milliseconds), `:ping` (address, timeout → result), `:pubsub`, `:topic`,
  `:registry`, `:on_awake` (called with the addresses once the device answers).
  """

  use GenServer, restart: :temporary

  alias Belgo.Inventory.Device
  alias Belgo.WakeOnLan.Outcome

  @doc "Starts a watch."
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) do
    device = Keyword.fetch!(options, :device)

    name =
      case Keyword.get(options, :registry) do
        nil -> nil
        registry -> {:via, Registry, {registry, device.id}}
      end

    GenServer.start_link(__MODULE__, options, name: name)
  end

  @impl GenServer
  def init(options) do
    device = Keyword.fetch!(options, :device)

    state = %{
      device: device,
      addresses: Device.ip_addresses(device),
      ping_interval: Keyword.fetch!(options, :ping_interval),
      ping_timeout: Keyword.fetch!(options, :ping_timeout),
      timeout: Keyword.fetch!(options, :timeout),
      ping: Keyword.fetch!(options, :ping),
      pubsub: Keyword.get(options, :pubsub),
      topic: Keyword.fetch!(options, :topic),
      on_awake: Keyword.get(options, :on_awake, fn _addresses -> :ok end),
      started_at: System.monotonic_time(:millisecond)
    }

    send(self(), :ping)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:ping, state) do
    elapsed = System.monotonic_time(:millisecond) - state.started_at

    cond do
      answering?(state) ->
        state.on_awake.(state.addresses)
        finish(state, :awake, elapsed)

      elapsed >= state.timeout ->
        finish(state, :timeout, elapsed)

      # The last ping happens when the timeout elapses.
      true ->
        Process.send_after(self(), :ping, min(state.ping_interval, state.timeout - elapsed))
        {:noreply, state}
    end
  end

  defp answering?(state) do
    state.addresses
    |> Task.async_stream(&state.ping.(&1, state.ping_timeout),
      timeout: :infinity,
      ordered: false
    )
    |> Enum.any?(&(&1 == {:ok, :up}))
  end

  defp finish(state, result, elapsed) do
    outcome = %Outcome{
      device_id: state.device.id,
      device_name: state.device.name,
      result: result,
      elapsed: elapsed,
      timeout: state.timeout
    }

    if state.pubsub,
      do: Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:wake_on_lan, outcome})

    {:stop, :normal, state}
  end
end
