defmodule Belgo.Providers.Proxmox.HttpClient do
  @moduledoc """
  Proxmox VE API over HTTP (`/api2/json`), authenticated with an API token:
  `Authorization: PVEAPIToken=USER@REALM!TOKENID=SECRET`.
  """

  @behaviour Belgo.Providers.Proxmox.Client

  alias Belgo.Providers.Proxmox.Config

  @api_prefix "/api2/json"
  @timeout_milliseconds 15_000

  @impl Belgo.Providers.Proxmox.Client
  def get(%Config{} = config, path) do
    config
    |> request()
    |> Req.get(url: path)
    |> handle_response(path)
  end

  defp request(config) do
    Req.new(
      base_url: config.url <> @api_prefix,
      headers: [authorization: "PVEAPIToken=#{config.token_id}=#{config.token_secret}"],
      receive_timeout: @timeout_milliseconds,
      retry: false,
      connect_options: [transport_opts: transport_options(config)]
    )
  end

  defp transport_options(%Config{verify_tls: true}), do: []
  defp transport_options(%Config{verify_tls: false}), do: [verify: :verify_none]

  defp handle_response({:ok, %Req.Response{status: 200, body: %{"data" => data}}}, _path),
    do: {:ok, data}

  defp handle_response({:ok, %Req.Response{status: 200, body: body}}, path),
    do: {:error, {:unexpected_body, path, body}}

  defp handle_response({:ok, %Req.Response{status: status}}, path),
    do: {:error, {:http_status, path, status}}

  defp handle_response({:error, exception}, path),
    do: {:error, {:request_failed, path, Exception.message(exception)}}
end
