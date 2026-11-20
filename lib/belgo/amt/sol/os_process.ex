defmodule Belgo.Amt.Sol.OsProcess do
  @moduledoc """
  Ends an operating system process for good. Closing an Erlang port only closes the
  program's stdin: amtterm exits on end of file once connected, but not while it is
  stuck connecting or authenticating. So the process gets `SIGTERM`, then `SIGKILL`
  if it still runs after a grace delay. Uses the `kill` executable (coreutils or
  busybox).
  """

  @poll_interval_milliseconds 50
  @fallback_executable "/bin/kill"

  @doc "Whether the process exists."
  @spec alive?(non_neg_integer()) :: boolean()
  def alive?(os_pid), do: match?({_output, 0}, kill("-0", os_pid))

  @doc "Terminates the process: `SIGTERM`, then `SIGKILL` after `grace` milliseconds."
  @spec terminate(non_neg_integer(), non_neg_integer()) :: :ok
  def terminate(os_pid, grace) do
    if alive?(os_pid) do
      kill("-TERM", os_pid)
      unless exited_within?(os_pid, grace), do: kill("-KILL", os_pid)
    end

    :ok
  end

  defp exited_within?(os_pid, remaining) when remaining <= 0, do: not alive?(os_pid)

  defp exited_within?(os_pid, remaining) do
    if alive?(os_pid) do
      Process.sleep(@poll_interval_milliseconds)
      exited_within?(os_pid, remaining - @poll_interval_milliseconds)
    else
      true
    end
  end

  defp kill(signal, os_pid),
    do: System.cmd(executable(), [signal, Integer.to_string(os_pid)], stderr_to_stdout: true)

  # The image has busybox's `/bin/kill` even when `PATH` is not set.
  defp executable, do: System.find_executable("kill") || @fallback_executable
end
