defmodule Belgo.Amt.SolTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Belgo.Amt.Credentials
  alias Belgo.Amt.Sol
  alias Belgo.Amt.Sol.Command
  alias Belgo.Amt.Sol.OsProcess
  alias Belgo.Amt.Sol.Scrollback
  alias Belgo.Amt.Target

  @username "smithers"
  @wait_milliseconds 2_000

  setup do
    on_exit(fn ->
      for %{device_id: device_id} <- Sol.sessions(@username), do: Sol.close(@username, device_id)
    end)
  end

  defp open(device_id, address, password, options \\ []) do
    Sol.open(
      Keyword.merge(
        [
          username: @username,
          device_id: device_id,
          device_name: "Burns Node",
          target: %Target{address: address},
          credentials: Credentials.new("admin", password),
          idle_timeout: 60_000
        ],
        options
      )
    )
  end

  defp receive_output(expected, received) do
    if received =~ expected do
      received
    else
      receive do
        {:amt_sol_output, _offset, data} -> receive_output(expected, received <> data)
      after
        @wait_milliseconds -> flunk("#{inspect(expected)} not received, got #{inspect(received)}")
      end
    end
  end

  test "the command passes the password in the environment only" do
    credentials = Credentials.new("admin", "excellent")
    target = %Target{address: "10.0.0.10"}

    assert ["-u", "admin", "10.0.0.10", "16994"] == Command.arguments(target, credentials)
    assert [{~c"AMT_PASSWORD", ~c"excellent"}] == Command.environment(credentials)

    tls_target = %{
      target
      | redirection_tls?: true,
        redirection_port: 16_995,
        ca_file: "/data/ca.pem"
    }

    assert ["-u", "admin", "-C", "/data/ca.pem", "10.0.0.10", "16995"] ==
             Command.arguments(tls_target, credentials)
  end

  test "opens a console, replays it, echoes input and closes on demand" do
    capture_log(fn ->
      assert {:ok, :opened} == open("burns-node", "10.0.0.10", "excellent")
      assert {:ok, :already_open} == open("burns-node", "10.0.0.10", "excellent")
      assert Sol.open?(@username, "burns-node")
      refute Sol.open?("homer", "burns-node")

      {:ok, content, _offset} = Sol.attach(@username, "burns-node")
      output = receive_output("connected now", content)
      assert output =~ "fake amtterm -u admin 10.0.0.10 16994"
      refute output =~ "excellent"

      Sol.input(@username, "burns-node", "release the hounds\n")
      receive_output("release the hounds", "")

      # A page coming back gets the whole scrollback.
      assert {:ok, content, offset} = Sol.attach(@username, "burns-node")
      assert content =~ "connected now"
      assert content =~ "release the hounds"
      assert offset == byte_size(content)

      assert [%{device_id: "burns-node", device_name: "Burns Node"}] = Sol.sessions(@username)

      Sol.close(@username, "burns-node")
      assert_receive {:amt_sol_closed, :manual}, @wait_milliseconds
      refute Sol.open?(@username, "burns-node")
    end)
  end

  test "a refused password ends the session with amtterm's exit status" do
    Phoenix.PubSub.subscribe(Belgo.PubSub, Sol.topic(@username, "smithers"))

    capture_log(fn ->
      assert {:ok, :opened} == open("smithers", "10.0.0.11", "mmm-donuts")
      assert_receive {:amt_sol_closed, {:exit_status, 1}}, @wait_milliseconds
    end)
  end

  test "amtterm exiting before its os pid is read still ends the session" do
    Phoenix.PubSub.subscribe(Belgo.PubSub, Sol.topic(@username, "smithers"))
    test_process = self()

    # Waits for the port to close, as when amtterm exits before `init/1` reads its pid.
    port_os_pid = fn port ->
      monitor = Port.monitor(port)
      assert_receive {:DOWN, ^monitor, :port, ^port, _reason}, @wait_milliseconds
      Port.info(port, :os_pid)
    end

    terminate_process = fn os_pid, _grace -> send(test_process, {:terminated, os_pid}) end

    capture_log(fn ->
      assert {:ok, :opened} ==
               open("smithers", "10.0.0.11", "mmm-donuts",
                 port_os_pid: port_os_pid,
                 terminate_process: terminate_process
               )

      assert_receive {:amt_sol_closed, {:exit_status, 1}}, @wait_milliseconds
      refute_received {:terminated, _os_pid}
    end)
  end

  test "closing a session without os pid terminates no process" do
    Phoenix.PubSub.subscribe(Belgo.PubSub, Sol.topic(@username, "burns-node"))
    test_process = self()
    terminate_process = fn os_pid, _grace -> send(test_process, {:terminated, os_pid}) end

    capture_log(fn ->
      assert {:ok, :opened} ==
               open("burns-node", "10.0.0.10", "excellent",
                 port_os_pid: fn _port -> nil end,
                 terminate_process: terminate_process
               )

      Sol.close(@username, "burns-node")
      assert_receive {:amt_sol_closed, :manual}, @wait_milliseconds
      refute_received {:terminated, _os_pid}
    end)
  end

  test "closes after the inactivity timeout" do
    Phoenix.PubSub.subscribe(Belgo.PubSub, Sol.topic(@username, "burns-node"))

    capture_log(fn ->
      assert {:ok, :opened} == open("burns-node", "10.0.0.10", "excellent", idle_timeout: 100)
      assert_receive {:amt_sol_closed, :idle}, @wait_milliseconds
    end)
  end

  test "a stuck amtterm ignoring stdin and SIGTERM is killed" do
    Phoenix.PubSub.subscribe(Belgo.PubSub, Sol.topic(@username, "stuck"))

    capture_log(fn ->
      assert {:ok, :opened} ==
               open("stuck", "10.0.0.66", "excellent", kill_grace: 200)

      {:ok, content, _offset} = Sol.attach(@username, "stuck")
      output = receive_output(~r/stuck pid \d+/, content)
      [_match, os_pid] = Regex.run(~r/stuck pid (\d+)/, output)
      os_pid = String.to_integer(os_pid)
      assert OsProcess.alive?(os_pid)

      Sol.close(@username, "stuck")
      assert_receive {:amt_sol_closed, :manual}, @wait_milliseconds
      refute OsProcess.alive?(os_pid)
    end)
  end

  test "a missing amtterm is reported" do
    capture_log(fn ->
      assert {:error, :amtterm_unavailable} ==
               open("burns-node", "10.0.0.10", "excellent", executable: "/nonexistent/amtterm")
    end)
  end

  test "TLS without CA file is refused" do
    capture_log(fn ->
      assert {:error, :ca_file_missing} ==
               Sol.open(
                 username: @username,
                 device_id: "burns-node",
                 device_name: "Burns Node",
                 target: %Target{address: "10.0.0.10", redirection_tls?: true},
                 credentials: Credentials.new("admin", "excellent"),
                 idle_timeout: 60_000
               )
    end)
  end

  test "the scrollback keeps the last bytes and counts all of them" do
    scrollback =
      4
      |> Scrollback.new()
      |> Scrollback.append("Mr. ")
      |> Scrollback.append("Burns")

    assert "urns" == scrollback.content
    assert 9 == scrollback.offset
  end
end
