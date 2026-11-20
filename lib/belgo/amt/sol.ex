defmodule Belgo.Amt.Sol do
  @moduledoc """
  Serial over LAN consoles of Intel AMT through `amtterm` (`Belgo.Amt.Sol.Session`,
  one per user and device). A session belongs to the user who opened it (Authelia
  `Remote-User`, or the static user): nobody else can attach to it.

  The executable is `config :belgo, Belgo.Amt.Sol, executable: …`, else
  `BELGO_AMTTERM_PATH`, else `amtterm` from `PATH` (tests use a fake script).
  Sessions live in memory: a restart of Belgo closes them.
  """

  alias Belgo.Amt.Credentials
  alias Belgo.Amt.Sol.Session
  alias Belgo.Amt.Target

  require Logger

  @registry Belgo.Amt.Sol.Registry
  @supervisor Belgo.Amt.Sol.Supervisor
  @default_executable "amtterm"

  @typedoc "A session as listed for its user."
  @type summary :: %{device_id: String.t(), device_name: String.t(), started_at: DateTime.t()}

  @doc "PubSub topic of the session of a user on a device."
  @spec topic(String.t(), String.t()) :: String.t()
  def topic(username, device_id), do: "amt_sol:#{username}:#{device_id}"

  @doc """
  Opens the console of a device for a user (`{:ok, :already_open}` when one runs:
  the typed credentials are then ignored).

  Options: `:username`, `:device_id`, `:device_name`, `:target`, `:credentials`,
  `:idle_timeout` (milliseconds); `:executable` overrides the configured one.
  """
  @spec open(Keyword.t()) ::
          {:ok, :opened | :already_open}
          | {:error, :amtterm_unavailable | :ca_file_missing | term()}
  def open(options) do
    %Target{} = target = Keyword.fetch!(options, :target)
    %Credentials{} = Keyword.fetch!(options, :credentials)
    username = Keyword.fetch!(options, :username)
    device_id = Keyword.fetch!(options, :device_id)
    log_prefix = "[amt] [sol] [#{device_id}] [#{username}]"
    Logger.debug("#{log_prefix} opening #{target.address}")

    with :ok <- Target.check_tls(target, :redirection),
         {:ok, executable} <- executable(Keyword.get(options, :executable)) do
      session_options =
        Keyword.merge(options,
          executable: executable,
          pubsub: Belgo.PubSub,
          topic: topic(username, device_id),
          registry: @registry
        )

      case DynamicSupervisor.start_child(@supervisor, {Session, session_options}) do
        {:ok, _pid} -> {:ok, :opened}
        {:error, {:already_started, _pid}} -> {:ok, :already_open}
        {:error, reason} -> log_failure(log_prefix, reason)
      end
    else
      {:error, reason} -> log_failure(log_prefix, reason)
    end
  end

  defp log_failure(log_prefix, reason) do
    Logger.error("#{log_prefix} failed: #{inspect(reason)}")
    {:error, reason}
  end

  @doc "Whether the user has a console open on the device."
  @spec open?(String.t(), String.t()) :: boolean()
  def open?(username, device_id), do: whereis(username, device_id) != nil

  @doc """
  Subscribes the caller to the session's output, then returns its scrollback and
  offset: output messages with an offset up to it are already in the scrollback.
  """
  @spec attach(String.t(), String.t()) :: {:ok, binary(), non_neg_integer()} | {:error, :closed}
  def attach(username, device_id) do
    # Attaching again (reconnection) must not subscribe twice.
    Phoenix.PubSub.unsubscribe(Belgo.PubSub, topic(username, device_id))
    Phoenix.PubSub.subscribe(Belgo.PubSub, topic(username, device_id))

    with pid when is_pid(pid) <- whereis(username, device_id),
         {content, offset} <- safe_call(pid, :scrollback) do
      {:ok, content, offset}
    else
      _closed -> {:error, :closed}
    end
  end

  @doc "Sends keyboard input to the console (resets its inactivity timer)."
  @spec input(String.t(), String.t(), binary()) :: :ok
  def input(username, device_id, data) do
    case whereis(username, device_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:input, data})
    end
  end

  @doc "Closes the console of the user on the device."
  @spec close(String.t(), String.t()) :: :ok
  def close(username, device_id) do
    case whereis(username, device_id) do
      nil ->
        :ok

      pid ->
        monitor = Process.monitor(pid)
        safe_call(pid, :close)

        # Returns once the session (and amtterm) is gone.
        receive do
          {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
        end
    end
  end

  @doc "The consoles open by a user, oldest first."
  @spec sessions(String.t()) :: [summary()]
  def sessions(username) do
    @registry
    |> Registry.select([
      {{{:"$1", :"$2"}, :"$3", :"$4"}, [{:==, :"$1", username}], [{{:"$2", :"$3", :"$4"}}]}
    ])
    |> Enum.filter(fn {_device_id, pid, _value} -> Process.alive?(pid) end)
    |> Enum.map(fn {device_id, _pid, value} -> Map.put(value, :device_id, device_id) end)
    |> Enum.sort_by(& &1.started_at, DateTime)
  end

  defp whereis(username, device_id) do
    case Registry.lookup(@registry, {username, device_id}) do
      # The registry forgets a stopped session a moment after it stops.
      [{pid, _value}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  defp safe_call(pid, message) do
    GenServer.call(pid, message)
  catch
    :exit, _reason -> nil
  end

  defp executable(nil) do
    configured =
      :belgo
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:executable)

    executable(configured || System.get_env("BELGO_AMTTERM_PATH", @default_executable))
  end

  defp executable(name) do
    path = if Path.type(name) == :absolute, do: name, else: System.find_executable(name)

    if path && File.exists?(path), do: {:ok, path}, else: {:error, :amtterm_unavailable}
  end
end
