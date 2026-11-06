defmodule Belgo.Reachability.Pinger do
  @moduledoc """
  Pings an address with the `ping` executable (iputils: exit 0 when answered, 1 when
  not). The executable is `BELGO_PING_PATH` (`ping` from `PATH` by default). It needs
  unprivileged ICMP (`net.ipv4.ping_group_range`) or `CAP_NET_RAW`.
  """

  alias Belgo.Reachability.Status

  @answered_exit_status 0
  @unanswered_exit_status 1
  @milliseconds_per_second 1_000
  @minimum_wait_seconds 1

  @doc "Sends one echo request and waits at most `timeout` milliseconds."
  @spec ping(String.t(), pos_integer()) :: Status.result()
  def ping(address, timeout) do
    seconds =
      max(
        @minimum_wait_seconds,
        div(timeout + @milliseconds_per_second - 1, @milliseconds_per_second)
      )

    case System.cmd(executable(), ["-n", "-c", "1", "-W", Integer.to_string(seconds), address],
           stderr_to_stdout: true
         ) do
      {_output, @answered_exit_status} -> :up
      {_output, @unanswered_exit_status} -> :down
      {output, status} -> {:error, {status, String.trim(output)}}
    end
  rescue
    error in ErlangError -> {:error, {:ping_unavailable, Exception.message(error)}}
  end

  defp executable, do: System.get_env("BELGO_PING_PATH", "ping")
end
