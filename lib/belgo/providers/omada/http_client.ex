defmodule Belgo.Providers.Omada.HttpClient do
  @moduledoc """
  Omada Open API (organization level, client credentials), as documented for
  controller 6.3.0 at https://omada-northbound-docs.tplinkcloud.com:

    * `POST /openapi/authorize/token?grant_type=client_credentials` with `omadacId`,
      `client_id` and `client_secret` returns `result.accessToken` (valid 2 hours)
    * calls send `Authorization: AccessToken=<token>`
    * `GET /openapi/v1/{omadacId}/sites`, `…/sites/{siteId}/devices` and
      `…/sites/{siteId}/clients` are paginated (`page`, `pageSize` ≤ 1000, `result.data`)
    * `PATCH …/sites/{siteId}/clients/{clientMac}/name` renames a client
    * `POST …/sites/{siteId}/clients/{clientMac}/reconnect` (no body) reconnects a
      wireless client (`-41025` "Unable to reconnect wired client")

    * `GET /openapi/v1/{omadacId}/correction-list` lists the client types
      (`result.typeList`)

  Type, vendor and model of a client have no Open API endpoint: they go through the
  controller's web API, as its interface does (captured on the owner's controller):
  `PATCH /{omadacId}/api/v2/sites/{siteId}/clients/{clientMac}` with
  `{"name", "clientInfoCorrection": {"type", "vendor", "model"}}`. Its login follows
  `tplink-omada-client` 1.5.14 (used by Home Assistant): `POST
  /{omadacId}/api/v2/login` `{username, password}` returns `result.token`, sent back
  as `Csrf-Token` with the `TPOMADA_SESSIONID` cookie; both APIs share site ids. A
  lost web session answers 200 with an HTML page.

  Every response wraps its payload as `{"errorCode": 0, "result": …}`. A token is
  requested for every session, so nothing is kept between pulls.
  """

  @behaviour Belgo.Providers.Omada.Client

  alias Belgo.Providers.Omada.Config

  @timeout_milliseconds 15_000
  @page_size 1000
  @session_cookie "TPOMADA_SESSIONID"
  @request_source "web-local"

  @impl Belgo.Providers.Omada.Client
  def open(%Config{} = config) do
    base = base_request(config)

    with {:ok, omadac_id} <- omadac_id(base, config),
         {:ok, token} <- access_token(base, omadac_id, config),
         request = Req.merge(base, headers: [{"authorization", "AccessToken=#{token}"}]),
         session = %{request: request, omadac_id: omadac_id},
         {:ok, site_id} <- site_id(session, config.site) do
      {:ok, Map.put(session, :site_id, site_id)}
    end
  end

  @impl Belgo.Providers.Omada.Client
  def devices(session), do: page(session, site_path(session, "devices"))

  @impl Belgo.Providers.Omada.Client
  def clients(session), do: page(session, site_path(session, "clients"))

  @impl Belgo.Providers.Omada.Client
  def rename_client(session, mac, name) do
    call(
      Req.patch(session.request,
        url: site_path(session, "clients/#{mac}/name"),
        json: %{name: name}
      )
    )
  end

  @impl Belgo.Providers.Omada.Client
  def reconnect_client(session, mac),
    do: call(Req.post(session.request, url: site_path(session, "clients/#{mac}/reconnect")))

  @impl Belgo.Providers.Omada.Client
  def correction_types(session) do
    with {:ok, result} <-
           call(Req.get(session.request, url: "/openapi/v1/#{session.omadac_id}/correction-list")) do
      {:ok, List.wrap(result["typeList"])}
    end
  end

  @impl Belgo.Providers.Omada.Client
  def open_web(%Config{} = config, session) do
    base = base_request(config)

    response =
      Req.post(base,
        url: "/#{session.omadac_id}/api/v2/login",
        json: %{username: config.username, password: config.password}
      )

    with {:ok, result} <- call(response),
         {:ok, token} <- fetch(result, "token"),
         {:ok, cookie} <- session_cookie(response) do
      request =
        Req.merge(base,
          headers: [
            {"csrf-token", token},
            {"cookie", cookie},
            {"omada-request-source", @request_source},
            {"referer", config.url <> "/"},
            {"origin", config.url}
          ]
        )

      {:ok, %{session | request: request}}
    end
  end

  @impl Belgo.Providers.Omada.Client
  def correct_client(web_session, mac, body) do
    call(
      Req.patch(web_session.request,
        url: "/#{web_session.omadac_id}/api/v2/sites/#{web_session.site_id}/clients/#{mac}",
        json: body
      )
    )
  end

  defp session_cookie({:ok, %Req.Response{} = response}) do
    cookie =
      response
      |> Req.Response.get_header("set-cookie")
      |> Enum.find_value(&matching_cookie/1)

    if cookie, do: {:ok, cookie}, else: {:error, {:missing, @session_cookie}}
  end

  defp matching_cookie(header) do
    [cookie | _attributes] = String.split(header, ";")
    cookie = String.trim(cookie)
    if String.starts_with?(cookie, @session_cookie <> "="), do: cookie
  end

  defp base_request(config) do
    Req.new(
      base_url: config.url,
      receive_timeout: @timeout_milliseconds,
      retry: false,
      connect_options: [
        transport_opts: if(config.verify_tls, do: [], else: [verify: :verify_none])
      ]
    )
  end

  defp omadac_id(_base, %Config{omada_id: omada_id}) when is_binary(omada_id), do: {:ok, omada_id}

  defp omadac_id(base, _config) do
    with {:ok, info} <- call(Req.get(base, url: "/api/info")), do: fetch(info, "omadacId")
  end

  defp access_token(base, omadac_id, config) do
    body = %{
      omadacId: omadac_id,
      client_id: config.client_id,
      client_secret: config.client_secret
    }

    with {:ok, result} <-
           call(
             Req.post(base,
               url: "/openapi/authorize/token",
               params: [grant_type: "client_credentials"],
               json: body
             )
           ) do
      fetch(result, "accessToken")
    end
  end

  defp site_id(session, name) do
    with {:ok, sites} <- page(session, "/openapi/v1/#{session.omadac_id}/sites") do
      case Enum.find(sites, &(&1["name"] == name)) do
        %{"siteId" => id} -> {:ok, id}
        _missing -> {:error, {:unknown_site, name, Enum.map(sites, & &1["name"])}}
      end
    end
  end

  defp page(session, path) do
    with {:ok, result} <-
           call(Req.get(session.request, url: path, params: [page: 1, pageSize: @page_size])) do
      {:ok, List.wrap(result["data"])}
    end
  end

  defp site_path(session, resource),
    do: "/openapi/v1/#{session.omadac_id}/sites/#{session.site_id}/#{resource}"

  defp call({:ok, %Req.Response{status: 200, body: %{"errorCode" => 0} = body}}),
    do: {:ok, Map.get(body, "result")}

  defp call({:ok, %Req.Response{body: %{"errorCode" => code} = body}}),
    do: {:error, {:omada_error, code, body["msg"]}}

  defp call({:ok, %Req.Response{status: 200}}), do: {:error, :not_logged_in}
  defp call({:ok, %Req.Response{status: status}}), do: {:error, {:http_status, status}}
  defp call({:error, exception}), do: {:error, {:request_failed, Exception.message(exception)}}

  defp fetch(map, key) do
    case map do
      %{^key => value} -> {:ok, value}
      _missing -> {:error, {:missing, key}}
    end
  end
end
