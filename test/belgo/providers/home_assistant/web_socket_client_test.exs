defmodule Belgo.Providers.HomeAssistant.WebSocketClientTest do
  use ExUnit.Case, async: true

  alias Belgo.Providers.HomeAssistant.Config
  alias Belgo.Providers.HomeAssistant.WebSocketClient

  @token "mmm-donuts"

  defmodule Socket do
    @moduledoc "Speaks the Home Assistant WebSocket protocol, as documented."
    @behaviour WebSock

    @impl WebSock
    def init(state), do: {:push, text(%{type: "auth_required", ha_version: "2026.11.0"}), state}

    @impl WebSock
    def handle_in({text, opcode: :text}, state) do
      case Jason.decode!(text) do
        %{"type" => "auth", "access_token" => token} when token == state.token ->
          {:push, text(%{type: "auth_ok"}), state}

        %{"type" => "auth"} ->
          {:stop, :normal, 1000,
           [text(%{type: "auth_invalid", message: "Invalid access token or password"})], state}

        %{"id" => id, "type" => "config/floor_registry/list"} ->
          floors = [%{floor_id: "ground_floor", name: "Ground Floor", level: 0, aliases: []}]
          {:push, [text(%{id: 99, type: "event"}), result(id, floors)], state}

        %{"id" => id, "type" => "config/area_registry/list"} ->
          areas = [%{area_id: "kitchen", name: "Kitchen", floor_id: "ground_floor", labels: []}]
          {:push, result(id, areas), state}
      end
    end

    @impl WebSock
    def handle_info(_message, state), do: {:ok, state}

    defp result(id, result), do: text(%{id: id, type: "result", success: true, result: result})
    defp text(message), do: {:text, Jason.encode!(message)}
  end

  defmodule Endpoint do
    @moduledoc "Upgrades `/api/websocket` only."
    @behaviour Plug

    @impl Plug
    def init(options), do: options

    @impl Plug
    def call(%Plug.Conn{request_path: "/api/websocket"} = conn, options) do
      conn
      |> WebSockAdapter.upgrade(
        Belgo.Providers.HomeAssistant.WebSocketClientTest.Socket,
        %{token: options[:token]},
        []
      )
      |> Plug.Conn.halt()
    end

    def call(conn, _options), do: Plug.Conn.send_resp(conn, 404, "")
  end

  setup do
    server =
      start_supervised!(
        {Bandit, plug: {Endpoint, token: @token}, port: 0, ip: :loopback, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    %{url: "http://127.0.0.1:#{port}"}
  end

  test "authenticates and lists floors and areas", %{url: url} do
    assert {:ok,
            %{
              floors: [%{"floor_id" => "ground_floor", "level" => 0}],
              areas: [%{"area_id" => "kitchen", "floor_id" => "ground_floor"}]
            }} = WebSocketClient.registries(%Config{url: url, token: @token})
  end

  test "an invalid token is reported", %{url: url} do
    assert {:error, {:auth_invalid, "Invalid access token or password"}} =
             WebSocketClient.registries(%Config{url: url, token: "duff"})
  end

  test "an unreachable instance is an error" do
    assert {:error, _reason} =
             WebSocketClient.registries(%Config{url: "http://127.0.0.1:1", token: @token})
  end

  @websocket_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  test "a first message sent in the same packet as the upgrade response is not lost" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        [_match, key] = Regex.run(~r/sec-websocket-key: (\S+)/i, request)
        accept = Base.encode64(:crypto.hash(:sha, key <> @websocket_guid))

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n",
            "sec-websocket-accept: #{accept}\r\n\r\n",
            text_frame(~s({"type":"auth_required"}))
          ])

        {:ok, _auth_frame} = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, text_frame(~s({"type":"auth_invalid","message":"Duff"})))
        :gen_tcp.close(socket)
      end)

    assert {:error, {:auth_invalid, "Duff"}} =
             WebSocketClient.registries(%Config{url: "http://127.0.0.1:#{port}", token: @token})

    Task.await(server)
    :gen_tcp.close(listener)
  end

  defp text_frame(text) when byte_size(text) < 126, do: <<0x81, byte_size(text), text::binary>>
end
