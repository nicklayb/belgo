defmodule BelgoWeb.VersionFooterTest do
  use BelgoWeb.ConnCase

  test "shows the version in the footer of a page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices")

    footer = element(view, "#version-footer")
    assert render(footer) =~ "v#{Belgo.version()}"
  end
end
