defmodule Belgo.Amt.Wsman.HttpClientTest do
  use ExUnit.Case, async: true

  alias Belgo.Amt.Credentials
  alias Belgo.Amt.Digest
  alias Belgo.Amt.Target
  alias Belgo.Amt.Wsman.HttpClient

  @realm "Digest:71E10000000000000000000000000000"
  @nonce "O8cAKcQAAAAAAAAAVMLfOImnqXeqbu9z"

  # A fake AMT: challenges like the owner's AMT 11.8 (measured header), checks the
  # Digest response for admin / excellent, then echoes the envelope it received.
  defmodule FakeAmt do
    @moduledoc false
    @behaviour Plug

    @impl Plug
    def init(options), do: options

    @impl Plug
    def call(conn, options) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Digest " <> _rest = header] ->
          if valid?(header, options),
            do: Plug.Conn.send_resp(conn, 200, "<Envelope>#{body}</Envelope>"),
            else: challenge(conn, options)

        _missing ->
          challenge(conn, options)
      end
    end

    defp challenge(conn, options) do
      conn
      |> Plug.Conn.put_resp_header(
        "www-authenticate",
        ~s(Digest realm="#{options[:realm]}", nonce="#{options[:nonce]}",stale="false",qop="auth")
      )
      |> Plug.Conn.send_resp(401, "")
    end

    defp valid?(header, options) do
      {:ok, parameters} = Digest.parse_challenge(header)

      expected =
        Digest.response(
          %{"realm" => options[:realm], "nonce" => options[:nonce], "qop" => "auth"},
          username: parameters["username"],
          password: options[:password],
          method: "POST",
          uri: parameters["uri"],
          client_nonce: parameters["cnonce"],
          nonce_count: parameters["nc"]
        )

      parameters["username"] == "admin" and parameters["uri"] == "/wsman" and
        parameters["response"] == expected
    end
  end

  setup do
    server =
      start_supervised!(
        {Bandit,
         plug: {FakeAmt, realm: @realm, nonce: @nonce, password: "excellent"},
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    %{port: port}
  end

  test "answers the Digest challenge", %{port: port} do
    assert {:ok, "<Envelope><Hello/></Envelope>"} ==
             HttpClient.post(target(port), Credentials.new("admin", "excellent"), "<Hello/>")
  end

  test "a wrong password is refused after one attempt", %{port: port} do
    assert {:error, :unauthorized} ==
             HttpClient.post(target(port), Credentials.new("admin", "mmm-donuts"), "<Hello/>")
  end

  test "a closed port fails the request" do
    {:ok, closed} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, closed_port} = :inet.port(closed)
    :gen_tcp.close(closed)

    assert {:error, {:request_failed, _message}} =
             HttpClient.post(
               target(closed_port),
               Credentials.new("admin", "excellent"),
               "<Hello/>"
             )
  end

  defp target(port), do: %Target{address: "127.0.0.1", timeout: 2_000, wsman_port: port}
end
