defmodule Belgo.Versioning.Server do
  @moduledoc """
  Commits the data directory with git when `config.yaml` has a `git` key.

  At boot, the directory becomes a repository when it is not one yet and pending
  changes are committed. Then every inventory change (`{:inventory_changed, _}`)
  restarts a `git.commit_delay` timer: the commit happens once the files are left
  alone that long, and before stopping. With a `git.remote`, `HEAD` is pushed every
  `git.push_interval` when it moved since the last push (in a task, so a slow remote
  never delays commits). It never pulls nor forces.

  `config.yaml` is read on each event, so its changes apply on the next one.

  Options: `:directory` (the data directory, where `config.yaml` lives), `:pubsub`,
  `:task_supervisor` (`Belgo.TaskSupervisor` by default), `:name`.
  """

  use GenServer

  require Logger

  alias Belgo.Config
  alias Belgo.Config.Git, as: GitConfig
  alias Belgo.Inventory.Store
  alias Belgo.Versioning
  alias Belgo.Versioning.Git

  @short_sha_length 7

  @doc "Starts the server."
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc "Commits the pending changes now instead of waiting for the delay."
  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  @doc "Pushes now (when a remote is configured), without waiting for the interval."
  @spec push(GenServer.server()) :: :ok
  def push(server \\ __MODULE__), do: GenServer.cast(server, :push)

  @impl GenServer
  def init(options) do
    Process.flag(:trap_exit, true)
    pubsub = Keyword.get(options, :pubsub)
    if pubsub, do: Phoenix.PubSub.subscribe(pubsub, Store.topic())

    {:ok,
     %{
       directory: Keyword.fetch!(options, :directory),
       task_supervisor: Keyword.get(options, :task_supervisor, Belgo.TaskSupervisor),
       commit_timer: nil,
       push_timer: nil,
       push_task: nil,
       pushed: nil
     }, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    case git_config(state) do
      nil -> {:noreply, schedule_push(state, nil)}
      git -> {:noreply, schedule_push(commit(state, git), git)}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, %{commit_timer: nil} = state), do: {:reply, :ok, state}

  def handle_call(:flush, _from, state) do
    Process.cancel_timer(state.commit_timer)
    {:reply, :ok, commit_configured(state)}
  end

  @impl GenServer
  def handle_cast(:push, state), do: {:noreply, start_push(state, git_config(state))}

  @impl GenServer
  def handle_info({:inventory_changed, _snapshot}, state) do
    case git_config(state) do
      nil -> {:noreply, state}
      git -> {:noreply, schedule_commit(state, git)}
    end
  end

  def handle_info(:commit, state), do: {:noreply, commit_configured(state)}

  def handle_info(:push, state) do
    git = git_config(state)
    {:noreply, start_push(schedule_push(state, git), git)}
  end

  def handle_info({reference, result}, %{push_task: reference} = state) do
    Process.demonitor(reference, [:flush])
    {:noreply, %{finish_push(state, result) | push_task: nil}}
  end

  def handle_info({:DOWN, reference, :process, _pid, reason}, %{push_task: reference} = state) do
    Logger.error("[git] push crashed: #{inspect(reason)}")
    {:noreply, %{state | push_task: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{commit_timer: nil}), do: :ok
  def terminate(_reason, state), do: commit_configured(state)

  defp git_config(state) do
    case Config.load(state.directory) do
      {:ok, config} ->
        config.git

      {:error, messages} ->
        Logger.error("[config] invalid, git disabled:\n  " <> Enum.join(messages, "\n  "))
        nil
    end
  end

  defp schedule_commit(state, git) do
    if state.commit_timer, do: Process.cancel_timer(state.commit_timer)
    %{state | commit_timer: Process.send_after(self(), :commit, git.commit_delay)}
  end

  defp schedule_push(state, git) do
    interval = if git, do: git.push_interval, else: GitConfig.default_push_interval()
    %{state | push_timer: Process.send_after(self(), :push, interval)}
  end

  defp commit_configured(state) do
    case git_config(state) do
      nil -> %{state | commit_timer: nil}
      git -> commit(state, git)
    end
  end

  defp commit(state, git) do
    with :ok <- ensure_repository(state.directory),
         {:ok, paths} <- Git.stage_all(state.directory) do
      commit_paths(state.directory, paths, git)
    else
      {:error, reason} -> Logger.error("[git] commit failed: #{format_error(reason)}")
    end

    %{state | commit_timer: nil}
  end

  defp ensure_repository(directory) do
    if Git.repository?(directory) do
      :ok
    else
      with {:ok, _output} <- Git.init(directory) do
        Logger.info("[git] repository created in #{directory}")
      end
    end
  end

  defp commit_paths(_directory, [], _git), do: :ok

  defp commit_paths(directory, paths, git) do
    Logger.debug("[git] committing #{Enum.join(paths, ", ")}")
    message = Versioning.commit_message(paths, not Git.committed?(directory))

    with {:ok, _output} <-
           Git.commit(directory, message, %{name: git.author_name, email: git.author_email}) do
      Logger.info("[git] committed #{Enum.join(paths, ", ")}")
    end
  end

  defp start_push(state, %GitConfig{remote: remote} = git)
       when is_binary(remote) and is_nil(state.push_task) do
    directory = state.directory
    pushed = state.pushed

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        push_head(directory, git, pushed)
      end)

    %{state | push_task: task.ref}
  end

  defp start_push(state, _git), do: state

  defp push_head(directory, git, pushed) do
    with {:ok, sha} <- Git.head(directory) do
      case {git.remote, git.branch, sha} do
        ^pushed -> :up_to_date
        target -> push_target(directory, target)
      end
    end
  end

  defp push_target(directory, {remote, branch, sha} = target) do
    Logger.debug("[git] pushing #{short(sha)} to #{remote}")

    with {:ok, environment} <- Versioning.credentials_environment(),
         {:ok, _output} <- Git.push(directory, remote, branch, environment),
         do: {:pushed, target}
  end

  defp finish_push(state, {:pushed, {remote, _branch, sha} = target}) do
    Logger.info("[git] pushed #{short(sha)} to #{remote}")
    %{state | pushed: target}
  end

  defp finish_push(state, :up_to_date), do: state

  defp finish_push(state, {:error, reason}) do
    Logger.error("[git] push failed: #{format_error(reason)}")
    state
  end

  defp short(sha), do: String.slice(sha, 0, @short_sha_length)

  defp format_error({:git, status, output}), do: "git exited with #{status}: #{output}"
  defp format_error(message) when is_binary(message), do: message
  defp format_error(reason), do: inspect(reason)
end
