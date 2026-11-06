defmodule Belgo.PortScan.Server do
  @moduledoc """
  Keeps the open ports of each address in memory (never persisted) and checks them in
  the background (`Belgo.TaskSupervisor`, one task per address). A result is reused
  while younger than `port_scan.cache_duration` of `config.yaml`; an address being
  checked is never checked twice. Changes are broadcast as
  `{:port_scan_changed, [AddressScan.t()]}` on `Belgo.PortScan.topic/0`.

  Options: `:directory` (where `config.yaml` lives), `:scan` (address, ports, timeout
  → open ports, `Belgo.PortScan.Scanner.open_ports/3` by default), `:ports`
  (`Belgo.PortScan.Ports.all/0` by default), `:clock`, `:pubsub`, `:topic`,
  `:task_supervisor`, `:name`.
  """

  use GenServer

  require Logger

  alias Belgo.Config
  alias Belgo.PortScan
  alias Belgo.PortScan.AddressScan
  alias Belgo.PortScan.Ports
  alias Belgo.PortScan.Scanner

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
       scan: Keyword.get(options, :scan, &Scanner.open_ports/3),
       ports: Keyword.get(options, :ports, Ports.all()),
       clock: Keyword.get(options, :clock, &DateTime.utc_now/0),
       pubsub: Keyword.get(options, :pubsub),
       topic: Keyword.get(options, :topic, PortScan.topic()),
       task_supervisor: Keyword.get(options, :task_supervisor, Belgo.TaskSupervisor),
       address_scans: %{},
       tasks: %{}
     }}
  end

  @impl GenServer
  def handle_call(:address_scans, _from, state), do: {:reply, state.address_scans, state}

  @impl GenServer
  def handle_cast({:scan, addresses, force?}, state) do
    config = load_config(state.directory)
    now = state.clock.()

    stale =
      addresses
      |> Enum.uniq()
      |> Enum.reject(fn address ->
        case Map.get(state.address_scans, address) do
          nil ->
            false

          %AddressScan{state: :pending} ->
            true

          address_scan ->
            not force? and AddressScan.fresh?(address_scan, now, config.cache_duration)
        end
      end)

    pending = Enum.map(stale, &%AddressScan{address: &1, state: :pending})
    state = Enum.reduce(stale, state, &start_scan(&2, &1, config.timeout))
    publish(state, pending)
    {:noreply, %{state | address_scans: merge(state.address_scans, pending)}}
  end

  @impl GenServer
  def handle_info({reference, open_ports}, state) when is_map_key(state.tasks, reference) do
    Process.demonitor(reference, [:flush])
    {:noreply, finish(state, reference, open_ports)}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, state)
      when is_map_key(state.tasks, reference) do
    Logger.error("[port_scan] #{state.tasks[reference]} crashed: #{inspect(reason)}")
    {:noreply, finish(state, reference, [])}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_scan(state, address, timeout) do
    scan = state.scan
    ports = state.ports

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        scan.(address, ports, timeout)
      end)

    %{state | tasks: Map.put(state.tasks, task.ref, address)}
  end

  defp finish(state, reference, open_ports) do
    {address, tasks} = Map.pop!(state.tasks, reference)

    address_scan = %AddressScan{
      address: address,
      state: :done,
      open_ports: open_ports,
      checked_ports: state.ports,
      scanned_at: state.clock.()
    }

    publish(state, [address_scan])
    %{state | tasks: tasks, address_scans: merge(state.address_scans, [address_scan])}
  end

  defp merge(address_scans, changes), do: Enum.into(changes, address_scans, &{&1.address, &1})

  defp publish(_state, []), do: :ok
  defp publish(%{pubsub: nil}, _address_scans), do: :ok

  defp publish(state, address_scans),
    do: Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:port_scan_changed, address_scans})

  defp load_config(directory) do
    case Config.load(directory) do
      {:ok, config} ->
        config.port_scan

      {:error, messages} ->
        Logger.error("[config] invalid, defaults used:\n  " <> Enum.join(messages, "\n  "))
        %Config{}.port_scan
    end
  end
end
