defmodule Belgo.Amt.Digest do
  @moduledoc """
  HTTP Digest authentication (RFC 2617, MD5, `qop=auth`), the scheme of AMT's
  WS-Management. Pure: the client nonce is given by the caller.

  Measured on the owner's AMT 11.8 and the bare `AMT` server: the challenge is
  `Digest realm="Digest:71E1…", nonce="…",stale="false",qop="auth"` (no `opaque`,
  no `algorithm`).
  """

  @challenge_parameter ~r/([a-zA-Z]+)\s*=\s*(?:"([^"]*)"|([^\s,]+))/
  @supported_quality "auth"
  @hexadecimal_base 16
  @nonce_count_digits 8
  @client_nonce_bytes 16

  @type challenge :: %{String.t() => String.t()}

  @doc "Parses a `WWW-Authenticate: Digest …` header into its parameters."
  @spec parse_challenge(String.t() | nil) :: {:ok, challenge()} | :error
  def parse_challenge("Digest " <> parameters) do
    challenge =
      for [_match, key | values] <- Regex.scan(@challenge_parameter, parameters),
          into: %{},
          do: {String.downcase(key), parameter_value(values)}

    if Map.has_key?(challenge, "realm") and Map.has_key?(challenge, "nonce"),
      do: {:ok, challenge},
      else: :error
  end

  def parse_challenge(_header), do: :error

  # A quoted value, or a plain one (the regular expression leaves out unmatched
  # trailing groups).
  defp parameter_value([quoted]), do: quoted
  defp parameter_value(["", plain]), do: plain
  defp parameter_value([quoted, _plain]), do: quoted

  @doc """
  The `Authorization` header answering a challenge for `method` and `uri`.
  `request_count` is the nonce count (1 for a fresh nonce).
  """
  @spec authorization(challenge(), Keyword.t()) :: String.t()
  def authorization(challenge, options) do
    username = Keyword.fetch!(options, :username)
    method = Keyword.fetch!(options, :method)
    uri = Keyword.fetch!(options, :uri)
    client_nonce = Keyword.fetch!(options, :client_nonce)
    nonce_count = format_count(Keyword.get(options, :request_count, 1))
    quality? = quality_auth?(challenge)

    response =
      response(challenge,
        username: username,
        password: Keyword.fetch!(options, :password),
        method: method,
        uri: uri,
        client_nonce: client_nonce,
        nonce_count: nonce_count
      )

    parameters =
      [
        {"username", quote_value(username)},
        {"realm", quote_value(challenge["realm"])},
        {"nonce", quote_value(challenge["nonce"])},
        {"uri", quote_value(uri)}
      ] ++
        if(quality?,
          do: [
            {"qop", @supported_quality},
            {"nc", nonce_count},
            {"cnonce", quote_value(client_nonce)}
          ],
          else: []
        ) ++
        [{"response", quote_value(response)}] ++
        if(challenge["opaque"], do: [{"opaque", quote_value(challenge["opaque"])}], else: [])

    "Digest " <> Enum.map_join(parameters, ", ", fn {key, value} -> "#{key}=#{value}" end)
  end

  @doc "The `response` value of RFC 2617 (`qop=auth`, or the legacy RFC 2069 form without qop)."
  @spec response(challenge(), Keyword.t()) :: String.t()
  def response(challenge, options) do
    first_hash =
      md5("#{options[:username]}:#{challenge["realm"]}:#{Keyword.fetch!(options, :password)}")

    second_hash = md5("#{options[:method]}:#{options[:uri]}")

    if quality_auth?(challenge) do
      md5(
        Enum.join(
          [
            first_hash,
            challenge["nonce"],
            options[:nonce_count],
            options[:client_nonce],
            @supported_quality,
            second_hash
          ],
          ":"
        )
      )
    else
      md5("#{first_hash}:#{challenge["nonce"]}:#{second_hash}")
    end
  end

  @doc "A random client nonce."
  @spec client_nonce() :: String.t()
  def client_nonce,
    do: Base.encode16(:crypto.strong_rand_bytes(@client_nonce_bytes), case: :lower)

  defp quality_auth?(challenge) do
    challenge
    |> Map.get("qop", "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.member?(@supported_quality)
  end

  defp format_count(count),
    do:
      count
      |> Integer.to_string(@hexadecimal_base)
      |> String.downcase()
      |> String.pad_leading(@nonce_count_digits, "0")

  defp quote_value(value), do: ~s("#{value}")

  defp md5(text), do: Base.encode16(:crypto.hash(:md5, text), case: :lower)
end
