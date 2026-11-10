defmodule Belgo.Discovery.Server do
  @moduledoc """
  Orchestrates the providers: pulls what they know (discovery), pushes device
  records to the providers in `write` mode and releases (deletes) what they hold for
  MAC addresses removed from the inventory. Nothing is persisted: a restart triggers a new pull.

  Every run re-reads `providers.yaml` (an invalid file is logged and shown, never
  fatal: the inventory stays usable) and runs providers concurrently. Runs log
  `debug` when they start, `info` when they succeed and `error` when they fail.
  Results are correlated again whenever the inventory changes, and broadcast as
  `{:discovery_changed, state}`. A push that changed a provider triggers a pull, so
  divergences reflect it. Providers with an `interval` are pulled again that long
  after each pull completes (one timer per provider).

  Options:

    * `:directory` – directory holding `providers.yaml` (required)
    * `:inventory` – inventory store, defaults to `Belgo.Inventory.Store`
    * `:environment` – secrets environment, defaults to the process environment
    * `:pubsub` / `:topic` – where to broadcast, no broadcast without `:pubsub`
    * `:refresh_on_start` – pull at boot, defaults to `true`
    * `:reachability` – reachability server pinging the unknown devices after each
      pull (`Belgo.Reachability.check/2`, recent results reused), none by default
    * `:name` – process name, defaults to the module name
  """

  use GenServer

  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.State
  alias Belgo.Inventory
  alias Belgo.Inventory.Device
  alias Belgo.Providers.Settings
  alias Belgo.Reachability
  alias Belgo.Providers.Settings.Configured
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.PushReport

  require Logger

  @default_topic "discovery"

  @doc "Starts the server."
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc "Default PubSub topic."
  @spec default_topic() :: String.t()
  def default_topic, do: @default_topic

  @impl GenServer
  def init(options) do
    pubsub = Keyword.get(options, :pubsub)
    if pubsub, do: Phoenix.PubSub.subscribe(pubsub, Inventory.Store.topic())
    inventory = Keyword.get(options, :inventory, Inventory.Store)

    state = %{
      directory: Keyword.fetch!(options, :directory),
      environment: Keyword.get_lazy(options, :environment, &System.get_env/0),
      inventory: inventory,
      pubsub: pubsub,
      reachability: Keyword.get(options, :reachability),
      topic: Keyword.get(options, :topic, @default_topic),
      tasks: %{},
      timers: %{},
      intervals: %{},
      snapshot: Inventory.snapshot(inventory),
      public: %State{}
    }

    if Keyword.get(options, :refresh_on_start, true), do: send(self(), :refresh)
    {:ok, recompute(state)}
  end

  @impl GenServer
  def handle_call(:state, _from, state), do: {:reply, state.public, state}

  @impl GenServer
  def handle_cast(:refresh, state), do: {:noreply, refresh(state)}

  def handle_cast({:refresh, provider_key}, state),
    do: {:noreply, with_settings(state, &start_pulls(state, &1, [provider_key]))}

  def handle_cast({:push, {_collection, _id} = owner}, state), do: {:noreply, push(state, owner)}

  def handle_cast({:release, {_collection, _id} = owner, mac_addresses}, state),
    do: {:noreply, release(state, owner, mac_addresses)}

  @impl GenServer
  def handle_info(:refresh, state), do: {:noreply, refresh(state)}

  def handle_info({:scheduled_pull, provider_key}, state) do
    state = Map.update!(state, :timers, &Map.delete(&1, provider_key))
    {:noreply, with_settings(state, &start_pulls(state, &1, [provider_key]))}
  end

  def handle_info({:inventory_changed, snapshot}, state) do
    {:noreply,
     state
     |> Map.put(:snapshot, snapshot)
     |> recompute()
     |> broadcast()}
  end

  def handle_info({reference, result}, state) when is_map_key(state.tasks, reference) do
    Process.demonitor(reference, [:flush])
    {:noreply, complete(state, reference, result)}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state)
      when is_map_key(state.tasks, reference) do
    {:noreply, complete(state, reference, {:error, {:crashed, reason}})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp refresh(state), do: with_settings(state, &start_pulls(state, &1, :all))

  defp start_pulls(state, settings, only) do
    running_pulls = for {_reference, %{run: :pull, module: module}} <- state.tasks, do: module

    state =
      state
      |> Map.update!(:public, &State.configure(&1, settings))
      |> Map.put(:intervals, Map.new(settings.configs, &{&1.module.key(), &1.interval}))

    settings.configs
    |> Enum.reject(&(&1.module in running_pulls))
    |> Enum.filter(&(only == :all or &1.module.key() in only))
    |> Enum.reduce(state, &start_pull/2)
    |> recompute()
    |> broadcast()
  end

  defp start_pull(%Configured{module: module, config: config}, state) do
    state
    |> start_task(module, :pull, fn -> module.discover(config) end)
    |> Map.update!(:public, &State.start(&1, module.key()))
  end

  defp push(state, owner), do: with_settings(state, &start_pushes(state, &1, owner))

  # `owner` is `{:devices, id}` or `{:virtual_ips, id}`; runs and logs use the id.
  defp start_pushes(state, settings, {_collection, record_id} = owner) do
    desired_state =
      state.inventory
      |> Inventory.snapshot()
      |> DesiredState.build()
      |> DesiredState.for_owner(owner)

    state = Map.update!(state, :public, &State.configure(&1, settings))

    writable = Settings.writable(settings)

    if writable == [],
      do: Logger.debug("[push] [#{record_id}] skipped, no provider in write mode")

    Enum.reduce(writable, state, fn %Configured{module: module, config: config}, accumulator ->
      start_task(accumulator, module, {:push, record_id}, fn ->
        module.push(config, desired_state)
      end)
    end)
  end

  defp release(state, owner, mac_addresses) do
    case unknown_mac_addresses(state.inventory, mac_addresses) do
      [] -> state
      released -> with_settings(state, &start_releases(state, &1, owner, released))
    end
  end

  # A MAC address given back to the inventory meanwhile (moved to another device) is kept.
  defp unknown_mac_addresses(inventory, mac_addresses) do
    known =
      inventory
      |> Inventory.snapshot()
      |> Map.fetch!(:devices)
      |> Enum.flat_map(&Device.mac_addresses/1)

    Enum.uniq(mac_addresses) -- known
  end

  defp start_releases(state, settings, {_collection, record_id}, mac_addresses) do
    state = Map.update!(state, :public, &State.configure(&1, settings))

    settings
    |> Settings.writable()
    |> Enum.filter(&releases?(&1.module))
    |> Enum.reduce(state, fn %Configured{module: module, config: config}, accumulator ->
      start_task(accumulator, module, {:push, record_id}, fn ->
        module.release(config, mac_addresses)
      end)
    end)
  end

  defp releases?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :release, 2)

  defp with_settings(state, function) do
    case Settings.load(state.directory, state.environment) do
      {:ok, settings} ->
        function.(settings)

      {:error, messages} ->
        Logger.error(
          "[discovery] invalid providers configuration, providers keep their last result:\n  " <>
            Enum.join(messages, "\n  ")
        )

        state
        |> Map.update!(:public, &State.put_settings_error(&1, messages))
        |> broadcast()
    end
  end

  defp start_task(state, module, run, function) do
    Logger.debug("#{log_prefix(module, run)} started")
    task = Task.Supervisor.async_nolink(Belgo.TaskSupervisor, function)
    started = %{run: run, module: module, started_at: System.monotonic_time(:millisecond)}

    Map.update!(state, :tasks, &Map.put(&1, task.ref, started))
  end

  defp complete(state, reference, result) do
    {%{run: run, module: module, started_at: started_at}, tasks} = Map.pop(state.tasks, reference)
    duration = System.monotonic_time(:millisecond) - started_at
    log_result(module, run, result, duration)

    %{state | tasks: tasks}
    |> record_result(module, run, result)
    |> recompute()
    |> ping_discovered(run)
    |> broadcast()
  end

  defp record_result(state, module, :pull, result) do
    state
    |> Map.update!(:public, &State.complete(&1, module.key(), result, DateTime.utc_now()))
    |> schedule_pull(module.key())
  end

  defp record_result(state, module, {:push, device_id}, result) do
    if match?({:ok, %PushReport{operations: [_ | _]}}, result),
      do: send(self(), :refresh)

    Map.update!(
      state,
      :public,
      &State.complete_push(&1, module.key(), device_id, result, DateTime.utc_now())
    )
  end

  defp ping_discovered(%{reachability: nil} = state, _run), do: state

  defp ping_discovered(state, :pull) do
    state.public.correlation
    |> Correlation.discovered_addresses()
    |> Reachability.check(server: state.reachability)

    state
  end

  defp ping_discovered(state, _run), do: state

  defp schedule_pull(state, provider_key) do
    with {:ok, previous} <- Map.fetch(state.timers, provider_key),
         do: Process.cancel_timer(previous)

    case Map.get(state.intervals, provider_key) do
      nil ->
        Map.update!(state, :timers, &Map.delete(&1, provider_key))

      interval ->
        timer = Process.send_after(self(), {:scheduled_pull, provider_key}, interval)
        Map.update!(state, :timers, &Map.put(&1, provider_key, timer))
    end
  end

  defp log_result(module, :pull, {:ok, report}, duration) do
    counts =
      report.counts
      |> Enum.sort()
      |> Enum.map_join(", ", fn {source, count} -> "#{count} #{source}" end)

    Logger.info("#{log_prefix(module, :pull)} completed in #{duration}ms: #{counts}")
    log_failures(module, :pull, report.failures)
  end

  defp log_result(module, {:push, _device_id} = run, {:ok, %PushReport{} = report}, duration) do
    Logger.info(
      "#{log_prefix(module, run)} completed in #{duration}ms: #{PushReport.summary(report)}"
    )

    log_failures(module, run, report.failures)
  end

  defp log_result(module, run, {:error, reason}, duration) do
    Logger.error("#{log_prefix(module, run)} failed after #{duration}ms: #{inspect(reason)}")
  end

  defp log_failures(module, run, failures) do
    for {service, reason} <- failures do
      Logger.error("#{log_prefix(module, run)} #{service} failed: #{inspect(reason)}")
    end
  end

  defp log_prefix(module, :pull), do: "[discovery] [#{module.key()}]"
  defp log_prefix(module, {:push, device_id}), do: "[push] [#{module.key()}] [#{device_id}]"

  defp recompute(state) do
    correlation = Correlation.build(state.snapshot, State.observations(state.public))
    Map.update!(state, :public, &State.put_correlation(&1, correlation))
  end

  defp broadcast(%{pubsub: nil} = state), do: state

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:discovery_changed, state.public})
    state
  end
end
