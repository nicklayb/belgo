defmodule BelgoWeb.Plugs.Locale do
  @moduledoc """
  Sets the Gettext locale of the request (`BelgoWeb.Locale.resolve/2`: the
  `belgo_locale` cookie, else `Accept-Language`), assigns `locale` for `<html lang>`
  and keeps it in the session for the LiveViews (`BelgoWeb.Hooks.Locale`).
  """

  @behaviour Plug

  import Plug.Conn

  alias BelgoWeb.Locale

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options) do
    conn = fetch_cookies(conn)

    accept_language = List.first(get_req_header(conn, "accept-language"))
    locale = Locale.resolve(conn.cookies[Locale.cookie()], accept_language)

    Gettext.put_locale(BelgoWeb.Gettext, locale)

    conn
    |> assign(:locale, locale)
    |> put_session("locale", locale)
  end
end
