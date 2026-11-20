defmodule Belgo.Amt.DetectionTest do
  use ExUnit.Case, async: true

  alias Belgo.Amt.Detection
  alias Belgo.Amt.Probe

  describe "parse_server_header/1" do
    # The three headers measured on the owner's network.
    test "reads Intel AMT, Intel Standard Manageability and the bare AMT header" do
      assert {:ok, :amt, "11.8.55.3510"} ==
               Detection.parse_server_header("Intel(R) Active Management Technology 11.8.55.3510")

      assert {:ok, :standard_manageability, "9.1.45"} ==
               Detection.parse_server_header("Intel(R) Standard Manageability 9.1.45")

      assert {:ok, :amt, nil} == Detection.parse_server_header("AMT")
    end

    test "refuses other servers" do
      assert :error == Detection.parse_server_header("nginx/1.27.0")
      assert :error == Detection.parse_server_header("Krusty Web Server AMT")
      assert :error == Detection.parse_server_header(nil)
    end
  end

  test "uses TLS only when the plain port is closed" do
    plain = %Detection{address: "10.0.0.10", open_ports: [16_992, 16_993, 16_994]}
    tls_only = %Detection{address: "10.0.0.10", open_ports: [16_993, 16_995]}

    refute Detection.wsman_tls?(plain)
    refute Detection.redirection_tls?(plain)
    assert Detection.wsman_tls?(tls_only)
    assert Detection.redirection_tls?(tls_only)
    assert Detection.serial_over_lan?(plain)
    refute Detection.serial_over_lan?(%Detection{address: "10.0.0.10", open_ports: [16_992]})
  end

  test "describes the product and its firmware" do
    assert "Intel AMT 11.8.55.3510" ==
             Detection.describe(%Detection{
               address: "10.0.0.10",
               open_ports: [],
               product: :amt,
               version: "11.8.55.3510"
             })

    assert "Intel ISM" ==
             Detection.describe(%Detection{
               address: "10.0.0.10",
               open_ports: [],
               product: :standard_manageability
             })
  end

  describe "Probe" do
    test "does nothing without an AMT port" do
      assert nil == Probe.detect("127.0.0.1", [22, 8006], 100)
    end

    test "confirms AMT with the Server header of its web server" do
      port = start_web_server("Intel(R) Active Management Technology 11.8.55.3510")
      assert {:ok, :amt, "11.8.55.3510"} == Probe.server("127.0.0.1", port, false, 1_000)
    end

    test "ignores another web server, or none" do
      port = start_web_server("Krusty Web Server")
      assert :error == Probe.server("127.0.0.1", port, false, 1_000)

      {:ok, closed} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, closed_port} = :inet.port(closed)
      :gen_tcp.close(closed)
      assert :error == Probe.server("127.0.0.1", closed_port, false, 1_000)
    end
  end

  defmodule WebServer do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(server_header), do: server_header

    @impl Plug
    def call(conn, server_header) do
      conn
      |> Plug.Conn.put_resp_header("server", server_header)
      |> Plug.Conn.send_resp(200, "")
    end
  end

  defp start_web_server(server_header) do
    server =
      start_supervised!(
        {Bandit, plug: {WebServer, server_header}, port: 0, ip: :loopback, startup_log: false},
        id: make_ref()
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    port
  end
end
