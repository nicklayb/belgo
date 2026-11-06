defmodule Belgo.Reachability.Server do
  @moduledoc """
  Keeps the last ping result of each device in memory (never persisted) and runs
  checks in the background (`Belgo.TaskSupervisor`), one at a time per device. A
  result is reused while younger than `ping.cache_duration` of `config.yaml` and
  computed for the same addresses. Changes are broadcast as
  `{:reachability_changed, status}` on `Belgo.Reachability.topic(device_id)`.

  Options: `:directory` (where `config.yaml` lives), `:ping` (a function of the
  address and the timeout, `Belgo.Reachability.Pinger.ping/2` by default), `:clock`
  (returns the current `DateTime`), `:pubsub`, `:name`.
  """

  use GenServer

  require Logger

  alias Belgo.Config
  alias Belgo.Reachability
  alias Belgo.Reachability.Pinger
  alias Belgo.Reachability.Status

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
       statuses: %{},
       tasks: %{}
     }}
  end

  @impl GenServer
  def handle_call({:status, device_id}, _from, state),
    do: {:reply, Map.get(state.statuses, device_id), state}

  def handle_call({:check, device_id, addresses, force?}, _from, state) do
    config = load_config(state.directory)
    current = Map.get(state.statuses, device_id)

    cond do
      addresses == [] ->
        status = %Status{device_id: device_id, state: :unknown, addresses: []}
        {:reply, status, put_status(state, status)}

      match?(%Status{state: :pending}, current) ->
        {:reply, current, state}

      not force? and Status.fresh?(current, addresses, config.ping.cache_duration, state.clock.()) ->
        {:reply, current, state}

      true ->
        state = start_check(state, device_id, addresses, config.ping.timeout)
        {:reply, Map.fetch!(state.statuses, device_id), state}
    end
  end

  @impl GenServer
  def handle_info({reference, results}, state) when is_map_key(state.tasks, reference) do
    Process.demonitor(reference, [:flush])
    {device_id, tasks} = Map.pop(state.tasks, reference)
    status = Status.from_results(device_id, results, state.clock.())

    Logger.debug("[reachability] [#{device_id}] #{status.state}")
    {:noreply, put_status(%{state | tasks: tasks}, status)}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state)
      when is_map_key(state.tasks, reference) do
    {device_id, tasks} = Map.pop(state.tasks, reference)
    results = %{"check" => {:error, {:crashed, reason}}}

    {:noreply,
     put_status(%{state | tasks: tasks}, Status.from_results(device_id, results, state.clock.()))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_check(state, device_id, addresses, timeout) do
    ping = state.ping

    task =
      Task.Supervisor.async_nolink(Belgo.TaskSupervisor, fn ->
        addresses
        |> Task.async_stream(&{&1, ping.(&1, timeout)},
          timeout: :infinity,
          max_concurrency: length(addresses)
        )
        |> Map.new(fn {:ok, result} -> result end)
      end)

    pending = %Status{
      device_id: device_id,
      state: :pending,
      addresses: Enum.sort(addresses),
      checked_at: previous_checked_at(state.statuses, device_id)
    }

    state
    |> Map.update!(:tasks, &Map.put(&1, task.ref, device_id))
    |> put_status(pending)
  end

  defp previous_checked_at(statuses, device_id) do
    case Map.fetch(statuses, device_id) do
      {:ok, %Status{checked_at: checked_at}} -> checked_at
      :error -> nil
    end
  end

  defp put_status(state, %Status{} = status) do
    if state.pubsub,
      do:
        Phoenix.PubSub.broadcast(
          state.pubsub,
          Reachability.topic(status.device_id),
          {:reachability_changed, status}
        )

    Map.update!(state, :statuses, &Map.put(&1, status.device_id, status))
  end

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
