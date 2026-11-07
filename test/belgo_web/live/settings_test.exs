defmodule BelgoWeb.SettingsTest do
  use BelgoWeb.ConnCase

  test "the user button leads to the settings and the language follows the browser", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, ~s(a[data-user-settings][href="/settings"]))

    french = put_req_header(conn, "accept-language", "fr-CA,fr;q=0.9,en;q=0.5")
    html = html_response(get(french, ~p"/settings"), 200)
    assert html =~ ~s(<html lang="fr")
    assert html =~ "Paramètres"
    assert html =~ ~s(id="locale-setting")
  end

  test "the stored choice (cookie) beats the browser", %{conn: conn} do
    html =
      conn
      |> put_req_header("accept-language", "fr")
      |> put_req_cookie("belgo_locale", "en")
      |> get(~p"/settings")
      |> html_response(200)

    assert html =~ ~s(<html lang="en")
    assert html =~ "Settings"
  end
end
