defmodule Belgo.Amt.Wsman.HttpClient do
  @moduledoc """
  WS-Management over HTTP with Req. Req has no Digest authentication: each envelope
  is posted once without credentials, and posted again with the `Authorization`
  computed from the `401` challenge (`Belgo.Amt.Digest`). A second `401` means the
  account was refused (AMT may lock the account after several refusals, so callers
  stop at the first one).

  TLS (16993) verifies the certificate against `amt.ca_file` only; the host name is
  not checked, as AMT certificates rarely name the address used.
  """

  @behaviour Belgo.Amt.Wsman.Client

  alias Belgo.Amt.Credentials
  alias Belgo.Amt.Digest
  alias Belgo.Amt.Target

  @content_type "application/soap+xml;charset=UTF-8"
  @wsman_path "/wsman"
  @http_method "POST"
  @success_status 200
  @unauthorized_status 401

  @impl Belgo.Amt.Wsman.Client
  def post(%Target{} = target, %Credentials{} = credentials, envelope) do
    request = request(target, envelope)

    with {:ok, %Req.Response{status: @unauthorized_status} = response} <- Req.post(request),
         {:ok, challenge} <- challenge(response) do
      request
      |> Req.merge(headers: [authorization: authorization(challenge, credentials)])
      |> Req.post()
      |> handle_response()
    else
      {:ok, %Req.Response{} = response} -> handle_response({:ok, response})
      {:error, %{__exception__: true} = exception} -> handle_response({:error, exception})
      :error -> {:error, :unauthorized}
    end
  end

  defp request(target, envelope) do
    Req.new(
      url: Target.wsman_url(target),
      body: envelope,
      headers: [content_type: @content_type],
      receive_timeout: target.timeout,
      retry: false,
      redirect: false,
      decode_body: false,
      connect_options: [timeout: target.timeout, transport_opts: transport_options(target)]
    )
  end

  defp transport_options(%Target{wsman_tls?: false}), do: []

  defp transport_options(%Target{wsman_tls?: true, ca_file: ca_file}),
    do:
      [verify: :verify_peer, cacertfile: ca_file, server_name_indication: :disable] ++
        no_host_check()

  defp no_host_check,
    do: [customize_hostname_check: [match_fun: fn _reference, _presented -> true end]]

  defp challenge(response) do
    response
    |> Req.Response.get_header("www-authenticate")
    |> Enum.find_value(:error, fn header ->
      case Digest.parse_challenge(header) do
        {:ok, challenge} -> {:ok, challenge}
        :error -> nil
      end
    end)
  end

  defp authorization(challenge, credentials) do
    Digest.authorization(challenge,
      username: credentials.username,
      password: Credentials.password(credentials),
      method: @http_method,
      uri: @wsman_path,
      client_nonce: Digest.client_nonce()
    )
  end

  defp handle_response({:ok, %Req.Response{status: @success_status, body: body}}),
    do: {:ok, body}

  defp handle_response({:ok, %Req.Response{status: @unauthorized_status}}),
    do: {:error, :unauthorized}

  # SOAP faults come with a 400 or 500 status and an envelope describing them.
  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when is_binary(body) and body != "" do
    if String.contains?(body, "Envelope"), do: {:ok, body}, else: {:error, {:http_status, status}}
  end

  defp handle_response({:ok, %Req.Response{status: status}}), do: {:error, {:http_status, status}}

  defp handle_response({:error, exception}),
    do: {:error, {:request_failed, Exception.message(exception)}}
end
