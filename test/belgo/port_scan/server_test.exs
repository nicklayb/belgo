defmodule Belgo.PortScan.ServerTest do
  use ExUnit.Case, async: true

  alias Belgo.PortScan
  alias Belgo.PortScan.AddressScan
  alias Belgo.PortScan.Scanner
  alias Belgo.PortScan.Server

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    pubsub = __MODULE__.PubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    task_supervisor = __MODULE__.Tasks
    start_supervised!({Task.Supervisor, name: task_supervisor})
    topic = "port_scan:#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(pubsub, topic)
    test_process = self()

    scan = fn address, ports, _timeout ->
      send(test_process, {:scanned, address})
      if address == "10.0.0.10", do: Enum.filter(ports, &(&1 in [22, 8006])), else: []
    end

    server =
      start_supervised!(
        {Server,
         directory: tmp_dir,
         scan: scan,
         ports: [22, 80, 8006],
         pubsub: pubsub,
         topic: topic,
         task_supervisor: task_supervisor,
         name: nil}
      )

    %{server: server}
  end

  test "checks addresses in the background and keeps the result", %{server: server} do
    PortScan.scan(["10.0.0.10", "10.0.0.11"], server: server)

    assert_receive {:port_scan_changed, pending}
    assert Enum.all?(pending, &(&1.state == :pending))

    assert_receive {:port_scan_changed,
                    [%AddressScan{address: "10.0.0.10", open_ports: [22, 8006]}]},
                   1_000

    assert_receive {:port_scan_changed, [%AddressScan{address: "10.0.0.11", open_ports: []}]},
                   1_000

    assert %{"10.0.0.10" => %AddressScan{state: :done, checked_ports: [22, 80, 8006]}} =
             PortScan.address_scans(server)
  end

  test "reuses a recent result unless forced", %{server: server} do
    PortScan.scan(["10.0.0.10"], server: server)
    assert_receive {:port_scan_changed, [%AddressScan{state: :done}]}, 1_000
    assert_received {:scanned, "10.0.0.10"}

    PortScan.scan(["10.0.0.10"], server: server)
    PortScan.address_scans(server)
    refute_received {:scanned, "10.0.0.10"}

    PortScan.scan(["10.0.0.10"], server: server, force: true)
    assert_receive {:port_scan_changed, [%AddressScan{state: :done}]}, 1_000
    assert_received {:scanned, "10.0.0.10"}
  end

  test "confirms Intel AMT on the open ports", %{tmp_dir: tmp_dir} do
    detection = %Belgo.Amt.Detection{address: "10.0.0.10", open_ports: [16_992], product: :amt}

    probe = fn
      "10.0.0.10", [16_992], _timeout -> detection
      _address, _open_ports, _timeout -> nil
    end

    server =
      start_supervised!(
        {Server,
         directory: tmp_dir,
         scan: fn address, _ports, _timeout ->
           if address == "10.0.0.10", do: [16_992], else: []
         end,
         probe: probe,
         ports: [16_992],
         task_supervisor: __MODULE__.Tasks,
         name: nil},
        id: :amt_server
      )

    PortScan.scan(["10.0.0.10", "10.0.0.11"], server: server)

    assert eventually(fn ->
             match?(
               %{
                 "10.0.0.10" => %AddressScan{state: :done, amt: ^detection},
                 "10.0.0.11" => %AddressScan{state: :done, amt: nil}
               },
               PortScan.address_scans(server)
             )
           end)
  end

  defp eventually(check, attempts \\ 50) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(check, attempts - 1)
    end
  end

  test "the scanner sees listening ports and closed ones" do
    {:ok, listening} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, open_port} = :inet.port(listening)
    {:ok, closed} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, closed_port} = :inet.port(closed)
    :gen_tcp.close(closed)

    assert [open_port] == Scanner.open_ports("127.0.0.1", [open_port, closed_port], 500)
    :gen_tcp.close(listening)
  end
end
