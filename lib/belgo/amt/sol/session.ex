defmodule Belgo.Amt.Sol.Session do
  @moduledoc """
  One serial over LAN console: owns the amtterm port, keeps the scrollback and
  broadcasts the output, so the console survives page changes and reconnections.
  Registered by `{username, device_id}` in `Belgo.Amt.Sol.Registry` (value: device
  name and start time), started under `Belgo.Amt.Sol.Supervisor`, never restarted.

  Ends when the user closes it (`:manual`), after `idle_timeout` without input
  (`:idle`; output does not count, a chatty console would never close) or when
  amtterm exits (`{:exit_status, status}`). Closing the port, then terminating the
  OS process (`Belgo.Amt.Sol.OsProcess`), leaves no amtterm behind.

  Broadcasts on its topic: `{:amt_sol_output, offset, data}` (`offset` = bytes
  received so far, data included) and `{:amt_sol_closed, reason}`.

  Options: `:username`, `:device_id`, `:device_name`, `:target`, `:credentials`,
  `:executable`, `:idle_timeout`, `:kill_grace` (milliseconds), `:pubsub`,
  `:topic`, `:registry`, `:terminate_process` (os pid, grace → :ok), `:port_os_pid`
  (port → os pid, `nil` once the port is closed; tests use it to replay the race).

  amtterm can exit before the session reads its os pid (a refused password fails
  at once): the os pid is then `nil` and the pending `exit_status` message ends the
  session through the normal path.
  The password is only read to build the port environment, never kept.
  """

  use GenServer, restart: :temporary

  alias Belgo.Amt.Sol.Command
  alias Belgo.Amt.Sol.OsProcess
  alias Belgo.Amt.Sol.Scrollback

  require Logger

  @default_kill_grace_milliseconds 1_000

  @type close_reason :: :manual | :idle | {:exit_status, integer()}

  @doc "Starts a session (the amtterm process starts with it)."
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) do
    key = {Keyword.fetch!(options, :username), Keyword.fetch!(options, :device_id)}

    name =
      case Keyword.get(options, :registry) do
        nil ->
          nil

        registry ->
          value = %{
            device_name: Keyword.fetch!(options, :device_name),
            started_at: DateTime.utc_now()
          }

          {:via, Registry, {registry, key, value}}
      end

    GenServer.start_link(__MODULE__, options, name: name)
  end

  @impl GenServer
  def init(options) do
    Process.flag(:trap_exit, true)
    target = Keyword.fetch!(options, :target)
    credentials = Keyword.fetch!(options, :credentials)

    port =
      Port.open({:spawn_executable, Keyword.fetch!(options, :executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Command.arguments(target, credentials),
        env: Command.environment(credentials)
      ])

    os_pid = Keyword.get(options, :port_os_pid, &port_os_pid/1).(port)
    idle_timeout = Keyword.fetch!(options, :idle_timeout)

    state = %{
      port: port,
      os_pid: os_pid,
      log_prefix:
        "[amt] [sol] [#{Keyword.fetch!(options, :device_id)}] [#{Keyword.fetch!(options, :username)}]",
      scrollback: Scrollback.new(),
      idle_timeout: idle_timeout,
      last_input_at: now(),
      pubsub: Keyword.get(options, :pubsub),
      topic: Keyword.fetch!(options, :topic),
      kill_grace: Keyword.get(options, :kill_grace, @default_kill_grace_milliseconds),
      terminate_process: Keyword.get(options, :terminate_process, &OsProcess.terminate/2),
      close_reason: nil
    }

    Process.send_after(self(), :check_idle, idle_timeout)
    Logger.info("#{state.log_prefix} opened to #{target.address}")
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:scrollback, _from, state),
    do: {:reply, {state.scrollback.content, state.scrollback.offset}, state}

  def handle_call(:close, _from, state),
    do: {:stop, :normal, :ok, %{state | close_reason: :manual}}

  @impl GenServer
  def handle_cast({:input, data}, state) do
    Port.command(state.port, data)
    {:noreply, %{state | last_input_at: now()}}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    scrollback = Scrollback.append(state.scrollback, data)
    broadcast(state, {:amt_sol_output, scrollback.offset, data})
    {:noreply, %{state | scrollback: scrollback}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, :normal, %{state | port: nil, close_reason: {:exit_status, status}}}

  def handle_info(:check_idle, state) do
    idle = now() - state.last_input_at

    if idle >= state.idle_timeout do
      {:stop, :normal, %{state | close_reason: :idle}}
    else
      Process.send_after(self(), :check_idle, state.idle_timeout - idle)
      {:noreply, state}
    end
  end

  # The port's own exit follows its `exit_status`, handled above.
  def handle_info({:EXIT, from, _reason}, state) when is_port(from), do: {:noreply, state}

  def handle_info({:EXIT, _from, reason}, state),
    do: {:stop, reason, %{state | close_reason: state.close_reason || :manual}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if state.port do
      safe_close(state.port)
      terminate_process(state)
    end

    reason = state.close_reason || :manual
    Logger.info("#{state.log_prefix} closed (#{describe(reason)})")
    broadcast(state, {:amt_sol_closed, reason})
  end

  defp terminate_process(%{os_pid: nil}), do: :ok
  defp terminate_process(state), do: state.terminate_process.(state.os_pid, state.kill_grace)

  @spec port_os_pid(port()) :: non_neg_integer() | nil
  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp describe({:exit_status, status}), do: "amtterm exited with #{status}"
  defp describe(reason), do: Atom.to_string(reason)

  defp broadcast(%{pubsub: nil}, _message), do: :ok
  defp broadcast(state, message), do: Phoenix.PubSub.broadcast(state.pubsub, state.topic, message)

  defp now, do: System.monotonic_time(:millisecond)
end
