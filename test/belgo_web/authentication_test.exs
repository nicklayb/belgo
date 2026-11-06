defmodule BelgoWeb.AuthenticationTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Belgo.Accounts.User
  alias BelgoWeb.Authentication

  @trusted_headers [mode: :trusted_headers]

  test "reads the user from the Authelia headers" do
    conn =
      :get
      |> conn("/")
      |> put_req_header("remote-user", "homer")
      |> put_req_header("remote-name", "Homer Simpson")
      |> put_req_header("remote-email", "homer@springfield.example")
      |> put_req_header("remote-groups", "admins, safety")

    assert {:ok,
            %User{
              username: "homer",
              name: "Homer Simpson",
              email: "homer@springfield.example",
              groups: ["admins", "safety"]
            }} == Authentication.user_from_conn(conn, @trusted_headers)
  end

  test "has no user without the headers" do
    assert :error == Authentication.user_from_conn(conn(:get, "/"), @trusted_headers)
  end

  test "the static mode always returns the configured user" do
    config = [mode: :static, static_user: [username: "marge", name: "Marge"]]

    assert {:ok, %User{username: "marge"}} =
             Authentication.user_from_conn(conn(:get, "/"), config)
  end

  test "users round trip through the session" do
    user = %User{username: "lisa", groups: ["saxophone"]}
    session = %{"current_user" => Map.from_struct(user)}

    assert {:ok, user} == Authentication.user_from_session(session)
    assert :error == Authentication.user_from_session(%{})
  end
end
