defmodule Belgo.Amt.DigestTest do
  use ExUnit.Case, async: true

  alias Belgo.Amt.Digest

  # The challenge measured on the owner's AMT 11.8.
  @measured_challenge ~s(Digest realm="Digest:71E10000000000000000000000000000", nonce="O8cAKcQAAAAAAAAAVMLfOImnqXeqbu9z",stale="false",qop="auth")

  test "parses AMT's challenge" do
    assert {:ok,
            %{
              "realm" => "Digest:71E10000000000000000000000000000",
              "nonce" => "O8cAKcQAAAAAAAAAVMLfOImnqXeqbu9z",
              "stale" => "false",
              "qop" => "auth"
            }} = Digest.parse_challenge(@measured_challenge)

    assert :error == Digest.parse_challenge("Basic realm=\"Springfield\"")
    assert :error == Digest.parse_challenge(nil)
  end

  # The worked example of RFC 2617 (section 3.5).
  test "computes the response of RFC 2617" do
    challenge = %{
      "realm" => "testrealm@host.com",
      "nonce" => "dcd98b7102dd2f0e8b11d0f600bfb0c093",
      "qop" => "auth,auth-int"
    }

    assert "6629fae49393a05397450978507c4ef1" ==
             Digest.response(challenge,
               username: "Mufasa",
               password: "Circle Of Life",
               method: "GET",
               uri: "/dir/index.html",
               client_nonce: "0a4f113b",
               nonce_count: "00000001"
             )
  end

  test "builds the authorization header" do
    {:ok, challenge} = Digest.parse_challenge(@measured_challenge)

    header =
      Digest.authorization(challenge,
        username: "admin",
        password: "excellent",
        method: "POST",
        uri: "/wsman",
        client_nonce: "smithers"
      )

    assert header =~ ~r/^Digest username="admin", realm="Digest:71E1/
    assert header =~ ~s(uri="/wsman", qop=auth, nc=00000001, cnonce="smithers", response=")
    refute header =~ "excellent"
  end
end
