defmodule BelgoWeb.Plugs.Authenticate do
  @moduledoc "Halts with `401` unless `BelgoWeb.Authentication` resolves a user."

  @behaviour Plug

  alias BelgoWeb.Authentication

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options) do
    case Authentication.user_from_conn(conn) do
      {:ok, user} ->
        conn
        |> Plug.Conn.assign(:current_user, user)
        |> Authentication.put_session(user)

      :error ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(:unauthorized, "Authentication required")
        |> Plug.Conn.halt()
    end
  end
end
