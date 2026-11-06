defmodule BelgoWeb.Authentication do
  @moduledoc """
  Resolves the current user. Belgo does not handle credentials itself: it sits
  behind Authelia (forward auth) and trusts the headers the proxy sets.

  Modes (`config :belgo, BelgoWeb.Authentication, mode: ...`):

    * `:trusted_headers` – reads `Remote-User`, `Remote-Name`, `Remote-Email` and
      `Remote-Groups`. The application must only be reachable through the proxy,
      otherwise anyone can forge these headers.
    * `:static` – always the configured `static_user`, for local development.
  """

  alias Belgo.Accounts.User

  @session_key "current_user"
  @user_header "remote-user"
  @name_header "remote-name"
  @email_header "remote-email"
  @groups_header "remote-groups"

  @doc "Resolves the user of a request according to the configured mode."
  @spec user_from_conn(Plug.Conn.t(), Keyword.t()) :: {:ok, User.t()} | :error
  def user_from_conn(%Plug.Conn{} = conn, config \\ config()) do
    case Keyword.fetch!(config, :mode) do
      :static -> {:ok, struct!(User, Keyword.fetch!(config, :static_user))}
      :trusted_headers -> user_from_headers(conn)
    end
  end

  @doc "Stores the user in the session so LiveViews can read it back."
  @spec put_session(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  def put_session(%Plug.Conn{} = conn, %User{} = user) do
    Plug.Conn.put_session(conn, @session_key, Map.from_struct(user))
  end

  @doc "Reads the user stored by `put_session/2` from a LiveView session."
  @spec user_from_session(map()) :: {:ok, User.t()} | :error
  def user_from_session(%{@session_key => %{username: username} = attributes})
      when is_binary(username) do
    {:ok, struct!(User, attributes)}
  end

  def user_from_session(_session), do: :error

  defp user_from_headers(conn) do
    case header(conn, @user_header) do
      nil ->
        :error

      username ->
        {:ok,
         %User{
           username: username,
           name: header(conn, @name_header),
           email: header(conn, @email_header),
           groups:
             conn
             |> header(@groups_header)
             |> split_groups()
         }}
    end
  end

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _rest] when value != "" -> value
      _missing -> nil
    end
  end

  defp split_groups(nil), do: []

  defp split_groups(groups) do
    groups
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp config, do: Application.fetch_env!(:belgo, __MODULE__)
end
