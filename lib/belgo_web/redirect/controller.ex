defmodule BelgoWeb.Redirect.Controller do
  @moduledoc "Permanent redirections of former pages (`/discovery` is now part of the Overview)."

  use BelgoWeb, :controller

  @doc "Sends `/discovery?…` to the Overview, keeping the query (the *Out of DHCP* filter)."
  def overview(conn, _params) do
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: "/" <> query)
  end
end
