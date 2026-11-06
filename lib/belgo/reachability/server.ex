defmodule Belgo.Reachability.Server do
  @moduledoc """
  Keeps the last ping of each address in memory (never persisted) and pings in the
  background (`Belgo.TaskSupervisor`), a limited number of addresses at a time per
  check.
  A result is reused while younger than `ping.cache_duration` of `config.yaml`.
  Changes are broadcast as `{:reachability_changed, [AddressStatus.t()]}` on
  `Belgo.Reachability.topic/0`: pending addresses right away, results grouped every
  few hundred milliseconds so a large check does not re-render pages for each answer.

  Options: `:directory` (where `config.yaml` lives), `:ping` (a function of the
  address and the timeout, `Belgo.Reachability.Pinger.ping/2` by default), `:clock`
  (returns the current `DateTime`), `:pubsub`, `:topic`, `:name`.
  """

  use GenServer

  require Logger

  alias Belgo.Config
  alias Belgo.Reachability
  alias Belgo.Reachability.AddressStatus
  alias Belgo.Reachability.Pinger

  @maximum_concurrent_pings 32
  @broadcast_delay_milliseconds 250

  @doc "Starts the server."
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl GenServer
  def init(options) do
    {:ok,
     %{
       directory: Keyword.fetch!(options, :directory),
       ping: Keyword.get(options, :ping, &Pinger.ping/2),
       clock: Keyword.get(options, :clock, &DateTime.utc_now/0),
       pubsub: Keyword.get(options, :pubsub),
       topic: Keyword.get(options, :topic, Reachability.topic()),
       address_statuses: %{},
       tasks: %{},
       unpublished: %{},
       broadcast_timer: nil
     }}
  end

  @impl GenServer
  def handle_call(:address_statuses, _from, state), do: {:reply, state.address_statuses, state}

  @impl GenServer
  def handle_cast({:check, addresses, force?}, state) do
    config = load_config(state.directory)
    now = state.clock.()

    stale =
      Enum.reject(addresses, fn address ->
        address_status = Map.get(state.address_statuses, address)

        AddressStatus.pending?(address_status) or
          (not force? and AddressStatus.fresh?(address_status, config.ping.cache_duration, now))
      end)

    if stale == [],
      do: {:noreply, state},
      else: {:noreply, start_check(state, stale, config.ping.timeout)}
  end

  @impl GenServer
  def handle_info({:pinged, address, result}, state) do
    address_status = %AddressStatus{address: address, result: result, checked_at: state.clock.()}
    Logger.debug("[reachability] [#{address}] #{inspect(result)}")
    {:noreply, put_result(state, address_status)}
  end

  def handle_info(:broadcast, state) do
    publish(state, Map.values(state.unpublished))
    {:noreply, %{state | unpublished: %{}, broadcast_timer: nil}}
  end

  def handle_info({reference, :done}, state) when is_map_key(state.tasks, reference) do
    Process.demonitor(reference, [:flush])
    {:noreply, Map.update!(state, :tasks, &Map.delete(&1, reference))}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state)
      when is_map_key(state.tasks, reference) do
    {addresses, tasks} = Map.pop(state.tasks, reference)

    state =
      addresses
      |> Enum.filter(&AddressStatus.pending?(Map.get(state.address_statuses, &1)))
      |> Enum.reduce(%{state | tasks: tasks}, fn address, accumulator ->
        failed = %AddressStatus{
          address: address,
          result: {:error, {:crashed, reason}},
          checked_at: state.clock.()
        }

        put_result(accumulator, failed)
      end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_check(state, addresses, timeout) do
    ping = state.ping
    server = self()

    task =
      Task.Supervisor.async_nolink(Belgo.TaskSupervisor, fn ->
        addresses
        |> Task.async_stream(&send(server, {:pinged, &1, ping.(&1, timeout)}),
          timeout: :infinity,
          max_concurrency: @maximum_concurrent_pings
        )
        |> Stream.run()

        :done
      end)

    pending =
      Enum.map(addresses, fn address ->
        %AddressStatus{
          address: address,
          result: :pending,
          checked_at: previous_checked_at(state.address_statuses, address)
        }
      end)

    publish(state, pending)

    state
    |> Map.update!(:tasks, &Map.put(&1, task.ref, addresses))
    |> Map.update!(:address_statuses, &Reachability.merge(&1, pending))
  end

  defp previous_checked_at(address_statuses, address) do
    case Map.fetch(address_statuses, address) do
      {:ok, %AddressStatus{checked_at: checked_at}} -> checked_at
      :error -> nil
    end
  end

  defp put_result(state, %AddressStatus{} = address_status) do
    state
    |> Map.update!(:address_statuses, &Map.put(&1, address_status.address, address_status))
    |> Map.update!(:unpublished, &Map.put(&1, address_status.address, address_status))
    |> schedule_broadcast()
  end

  defp schedule_broadcast(%{broadcast_timer: nil} = state),
    do: %{
      state
      | broadcast_timer: Process.send_after(self(), :broadcast, @broadcast_delay_milliseconds)
    }

  defp schedule_broadcast(state), do: state

  defp publish(%{pubsub: nil}, _address_statuses), do: :ok
  defp publish(_state, []), do: :ok

  defp publish(state, address_statuses),
    do:
      Phoenix.PubSub.broadcast(
        state.pubsub,
        state.topic,
        {:reachability_changed, address_statuses}
      )

  defp load_config(directory) do
    case Config.load(directory) do
      {:ok, config} ->
        config

      {:error, messages} ->
        Logger.error("[config] invalid, defaults used:\n  " <> Enum.join(messages, "\n  "))
        %Config{}
    end
  end
end
