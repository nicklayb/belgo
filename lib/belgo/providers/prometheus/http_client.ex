defmodule Belgo.Providers.Prometheus.HttpClient do
  @moduledoc """
  Prometheus HTTP API (`GET /api/v1/query`), queried directly or through Grafana's
  data source proxy (`/api/datasources/proxy/uid/<uid>/api/v1/query`, same answer)
  when the configuration names a data source. An optional token is sent as a bearer
  (a Grafana service account token, or a reverse proxy's).
  """

  @behaviour Belgo.Providers.Prometheus.Client

  alias Belgo.Providers.Prometheus.Config

  @query_path "/api/v1/query"
  @grafana_proxy_path "/api/datasources/proxy/uid"
  @timeout_milliseconds 15_000

  @impl Belgo.Providers.Prometheus.Client
  def query(%Config{} = config, promql) do
    path = query_path(config)

    config
    |> request()
    |> Req.get(url: path, params: [query: promql])
    |> handle_response(path)
  end

  @doc "Path of the query endpoint, through Grafana when a data source is configured."
  @spec query_path(Config.t()) :: String.t()
  def query_path(%Config{datasource_uid: nil}), do: @query_path

  def query_path(%Config{datasource_uid: uid}),
    do: "#{@grafana_proxy_path}/#{URI.encode(uid, &URI.char_unreserved?/1)}#{@query_path}"

  defp request(config) do
    Req.new(
      base_url: config.url,
      headers: authorization(config),
      receive_timeout: @timeout_milliseconds,
      retry: false,
      connect_options: [transport_opts: transport_options(config)]
    )
  end

  defp authorization(%Config{token: nil}), do: []
  defp authorization(%Config{token: token}), do: [authorization: "Bearer #{token}"]

  defp transport_options(%Config{verify_tls: true}), do: []
  defp transport_options(%Config{verify_tls: false}), do: [verify: :verify_none]

  defp handle_response(
         {:ok,
          %Req.Response{
            status: 200,
            body: %{"status" => "success", "data" => %{"result" => result}}
          }},
         _path
       )
       when is_list(result),
       do: {:ok, result}

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, path),
    do: {:error, {:unexpected_body, path, body}}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, path),
    do: {:error, {:http_status, path, status, body}}

  defp handle_response({:error, exception}, path),
    do: {:error, {:request_failed, path, Exception.message(exception)}}
end
