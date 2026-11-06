defmodule Belgo.Providers.Opnsense.HttpClient do
  @moduledoc """
  OPNsense API over HTTP. Authenticates with the API key and secret as basic
  credentials and requests every row of searches at once (`rowCount: -1`).
  """

  @behaviour Belgo.Providers.Opnsense.Client

  alias Belgo.Providers.Opnsense.Config

  @all_rows -1
  @timeout_milliseconds 15_000

  @impl Belgo.Providers.Opnsense.Client
  def search(%Config{} = config, path) do
    config
    |> request()
    |> Req.post(url: path, json: %{current: 1, rowCount: @all_rows, searchPhrase: ""})
    |> handle_response(path)
  end

  @impl Belgo.Providers.Opnsense.Client
  def post(%Config{} = config, path, body) do
    case Req.post(request(config), url: path, json: body) do
      {:ok, %Req.Response{status: 200, body: response}} when is_map(response) -> {:ok, response}
      response -> handle_response(response, path)
    end
  end

  defp request(config) do
    Req.new(
      base_url: config.url,
      auth: {:basic, "#{config.api_key}:#{config.api_secret}"},
      receive_timeout: @timeout_milliseconds,
      retry: false,
      connect_options: [transport_opts: transport_options(config)]
    )
  end

  defp transport_options(%Config{verify_tls: true}), do: []
  defp transport_options(%Config{verify_tls: false}), do: [verify: :verify_none]

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"rows" => rows}}}, _path)
       when is_list(rows),
       do: {:ok, rows}

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, path),
    do: {:error, {:unexpected_body, path, body}}

  defp handle_response({:ok, %Req.Response{status: status}}, path),
    do: {:error, {:http_status, path, status}}

  defp handle_response({:error, exception}, path),
    do: {:error, {:request_failed, path, Exception.message(exception)}}
end
