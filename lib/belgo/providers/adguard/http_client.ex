defmodule Belgo.Providers.Adguard.HttpClient do
  @moduledoc "AdGuard Home API over HTTP, authenticated with basic credentials."

  @behaviour Belgo.Providers.Adguard.Client

  alias Belgo.Providers.Adguard.Config

  @timeout_milliseconds 15_000

  @impl Belgo.Providers.Adguard.Client
  def get(%Config{} = config, path) do
    config
    |> request()
    |> Req.get(url: path)
    |> handle_response(path)
  end

  @impl Belgo.Providers.Adguard.Client
  def request(%Config{} = config, method, path, body) when method in [:post, :put] do
    config
    |> request()
    |> Req.request(method: method, url: path, json: body)
    |> handle_response(path)
  end

  defp request(config) do
    Req.new(
      base_url: config.url,
      auth: {:basic, "#{config.username}:#{config.password}"},
      receive_timeout: @timeout_milliseconds,
      retry: false,
      connect_options: [transport_opts: transport_options(config)]
    )
  end

  defp transport_options(%Config{verify_tls: true}), do: []
  defp transport_options(%Config{verify_tls: false}), do: [verify: :verify_none]

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, _path), do: {:ok, body}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, path),
    do: {:error, {:http_status, path, status, body}}

  defp handle_response({:error, exception}, path),
    do: {:error, {:request_failed, path, Exception.message(exception)}}
end
