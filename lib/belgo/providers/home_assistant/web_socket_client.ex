defmodule Belgo.Providers.HomeAssistant.WebSocketClient do
  @moduledoc """
  Reads the Home Assistant registries through its WebSocket API
  (https://developers.home-assistant.io/docs/api/websocket, commands from
  `homeassistant/components/config/{floor,area}_registry.py`):

    1. the server sends `auth_required`, the client answers
       `{"type": "auth", "access_token": …}`, the server replies `auth_ok` (or
       `auth_invalid` with a `message`)
    2. every command carries an `id`, answered by
       `{"id", "type": "result", "success", "result"}` (or `error` on failure)

  `config/floor_registry/list` and `config/area_registry/list` need no
  administrator. One connection per pull, closed afterwards.
  """

  @behaviour Belgo.Providers.HomeAssistant.Client

  alias Belgo.Providers.HomeAssistant.Config

  @timeout_milliseconds 15_000
  @websocket_path "/api/websocket"
  @command_by_id %{1 => "config/floor_registry/list", 2 => "config/area_registry/list"}
  @empty_upgrade %{status: nil, headers: [], data: "", done?: false}
  @floors_id 1
  @areas_id 2

  @impl Belgo.Providers.HomeAssistant.Client
  def registries(%Config{} = config) do
    with {:ok, connection} <- connect(config) do
      result =
        with {:ok, connection} <- authenticate(connection, config.token),
             {:ok, connection} <- send_commands(connection),
             {:ok, connection, result_by_id} <- receive_results(connection, %{}) do
          {:ok, connection,
           %{
             floors: Map.fetch!(result_by_id, @floors_id),
             areas: Map.fetch!(result_by_id, @areas_id)
           }}
        end

      close(result, connection)
    end
  end

  defp connect(config) do
    uri = URI.parse(config.url)
    {http_scheme, websocket_scheme} = schemes(uri.scheme)
    path = String.trim_trailing(uri.path || "", "/") <> @websocket_path

    transport_options =
      if http_scheme == :https and not config.verify_tls, do: [verify: :verify_none], else: []

    with {:ok, conn} <-
           Mint.HTTP.connect(http_scheme, uri.host, uri.port,
             mode: :passive,
             protocols: [:http1],
             transport_opts: [timeout: @timeout_milliseconds] ++ transport_options
           ),
         {:ok, conn, request_ref} <- upgrade(websocket_scheme, conn, path),
         {:ok, conn, upgrade} <- receive_upgrade(conn, request_ref, @empty_upgrade),
         {:ok, conn, websocket} <- new_websocket(conn, request_ref, upgrade) do
      connection = %{conn: conn, websocket: websocket, request_ref: request_ref, pending: []}
      buffer_early_messages(connection, upgrade.data)
    else
      {:error, %{__exception__: true} = error} -> {:error, Exception.message(error)}
      {:error, _conn, error} -> close_with_error(error)
      {:error, reason} -> {:error, reason}
    end
  end

  defp schemes("https"), do: {:https, :wss}
  defp schemes(_http), do: {:http, :ws}

  defp upgrade(websocket_scheme, conn, path) do
    case Mint.WebSocket.upgrade(websocket_scheme, conn, path, []) do
      {:ok, conn, request_ref} -> {:ok, conn, request_ref}
      {:error, conn, error} -> {:error, conn, error}
    end
  end

  # Frames sent right after the 101 response (Home Assistant sends `auth_required`
  # immediately) can arrive in the same packet: Mint returns them as `:data` of the
  # upgrade request, they must be decoded once the WebSocket exists.
  defp receive_upgrade(conn, request_ref, upgrade) do
    case Mint.WebSocket.recv(conn, 0, @timeout_milliseconds) do
      {:ok, conn, responses} ->
        upgrade = Enum.reduce(responses, upgrade, &upgrade_response(&1, &2, request_ref))

        if upgrade.done?,
          do: {:ok, conn, upgrade},
          else: receive_upgrade(conn, request_ref, upgrade)

      {:error, conn, error, _responses} ->
        {:error, conn, error}
    end
  end

  defp upgrade_response({:status, request_ref, status}, upgrade, request_ref),
    do: %{upgrade | status: status}

  defp upgrade_response({:headers, request_ref, headers}, upgrade, request_ref),
    do: %{upgrade | headers: headers}

  defp upgrade_response({:data, request_ref, data}, upgrade, request_ref),
    do: %{upgrade | data: upgrade.data <> data}

  defp upgrade_response({:done, request_ref}, upgrade, request_ref),
    do: %{upgrade | done?: true}

  defp upgrade_response(_other, upgrade, _request_ref), do: upgrade

  defp new_websocket(conn, request_ref, upgrade) do
    case Mint.WebSocket.new(conn, request_ref, upgrade.status, upgrade.headers, mode: :passive) do
      {:ok, conn, websocket} -> {:ok, conn, websocket}
      {:error, conn, error} -> {:error, conn, error}
    end
  end

  defp buffer_early_messages(connection, ""), do: {:ok, connection}

  defp buffer_early_messages(connection, data) do
    with {:ok, websocket, frames} <- decode_data(connection.websocket, data),
         {:ok, messages} <- messages(frames) do
      {:ok, %{connection | websocket: websocket, pending: messages}}
    end
  end

  defp authenticate(connection, token) do
    with {:ok, connection, %{"type" => "auth_required"}} <- receive_message(connection),
         {:ok, connection} <- send_message(connection, %{type: "auth", access_token: token}),
         {:ok, connection, message} <- receive_message(connection) do
      case message do
        %{"type" => "auth_ok"} -> {:ok, connection}
        %{"type" => "auth_invalid"} -> {:error, {:auth_invalid, message["message"]}}
        other -> {:error, {:unexpected_message, other}}
      end
    else
      {:ok, _connection, other} -> {:error, {:unexpected_message, other}}
      error -> error
    end
  end

  defp send_commands(connection) do
    Enum.reduce_while(@command_by_id, {:ok, connection}, fn {id, command}, {:ok, connection} ->
      case send_message(connection, %{id: id, type: command}) do
        {:ok, connection} -> {:cont, {:ok, connection}}
        error -> {:halt, error}
      end
    end)
  end

  defp receive_results(connection, result_by_id)
       when map_size(result_by_id) == map_size(@command_by_id),
       do: {:ok, connection, result_by_id}

  defp receive_results(connection, result_by_id) do
    with {:ok, connection, message} <- receive_message(connection) do
      case message do
        %{"type" => "result", "id" => id, "success" => true, "result" => result}
        when is_map_key(@command_by_id, id) and is_list(result) ->
          receive_results(connection, Map.put(result_by_id, id, result))

        %{"type" => "result", "id" => id, "success" => false} = failure ->
          {:error, {:command_failed, Map.get(@command_by_id, id), failure["error"]}}

        _event_or_other ->
          receive_results(connection, result_by_id)
      end
    end
  end

  defp send_message(connection, message) do
    with {:ok, websocket, data} <-
           Mint.WebSocket.encode(connection.websocket, {:text, Jason.encode!(message)}),
         {:ok, conn} <-
           Mint.WebSocket.stream_request_body(connection.conn, connection.request_ref, data) do
      {:ok, %{connection | conn: conn, websocket: websocket}}
    else
      {:error, _websocket_or_conn, error} -> {:error, error}
    end
  end

  defp receive_message(%{pending: [message | pending]} = connection),
    do: {:ok, %{connection | pending: pending}, message}

  defp receive_message(connection) do
    with {:ok, conn, responses} <- recv(connection.conn),
         {:ok, websocket, frames} <- decode(connection, responses) do
      connection = %{connection | conn: conn, websocket: websocket}

      case messages(frames) do
        {:ok, messages} -> receive_message(%{connection | pending: messages})
        error -> error
      end
    end
  end

  defp recv(conn) do
    case Mint.WebSocket.recv(conn, 0, @timeout_milliseconds) do
      {:ok, conn, responses} -> {:ok, conn, responses}
      {:error, _conn, error, _responses} -> {:error, error}
    end
  end

  defp decode(connection, responses) do
    data = for {:data, ref, data} <- responses, ref == connection.request_ref, into: "", do: data
    decode_data(connection.websocket, data)
  end

  defp decode_data(websocket, data) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} -> {:ok, websocket, frames}
      {:error, _websocket, error} -> {:error, error}
    end
  end

  defp messages(frames) do
    Enum.reduce_while(frames, {:ok, []}, fn
      {:text, text}, {:ok, messages} ->
        case Jason.decode(text) do
          {:ok, decoded} -> {:cont, {:ok, messages ++ List.wrap(decoded)}}
          {:error, error} -> {:halt, {:error, error}}
        end

      {:close, code, reason}, {:ok, []} ->
        {:halt, {:error, {:closed, code, reason}}}

      {:close, _code, _reason}, {:ok, messages} ->
        {:halt, {:ok, messages}}

      _ping_pong_or_binary, accumulator ->
        {:cont, accumulator}
    end)
  end

  defp close({:ok, connection, registries}, _initial_connection) do
    Mint.HTTP.close(connection.conn)
    {:ok, registries}
  end

  defp close(error, connection) do
    Mint.HTTP.close(connection.conn)
    error
  end

  defp close_with_error(%{__exception__: true} = error), do: {:error, Exception.message(error)}
  defp close_with_error(error), do: {:error, error}
end
