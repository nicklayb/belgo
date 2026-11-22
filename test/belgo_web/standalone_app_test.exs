defmodule BelgoWeb.StandaloneAppTest do
  use BelgoWeb.ConnCase

  alias BelgoWeb.Components.Layouts

  describe "root layout" do
    test "links the manifest with credentials and declares the standalone tags", %{conn: conn} do
      document =
        conn
        |> get(~p"/devices")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert attribute(document, ~s(link[rel="manifest"]), "href") == "/manifest.webmanifest"
      assert attribute(document, ~s(link[rel="manifest"]), "crossorigin") == "use-credentials"
      assert meta_content(document, "apple-mobile-web-app-capable") == "yes"
      assert meta_content(document, "mobile-web-app-capable") == "yes"

      assert meta_content(document, "apple-mobile-web-app-status-bar-style") ==
               "black-translucent"

      assert meta_content(document, "apple-mobile-web-app-title") == "Belgo"
      assert attribute(document, ~s(meta[name="viewport"]), "content") =~ "viewport-fit=cover"

      media_queries =
        document
        |> LazyHTML.query(~s(meta[name="theme-color"]))
        |> LazyHTML.attribute("media")

      assert media_queries == ["(prefers-color-scheme: light)", "(prefers-color-scheme: dark)"]
    end

    test "the mobile drawer has a close button and closes when a link is tapped", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/devices")

      assert has_element?(view, "#mobile-menu #mobile-menu-close")
      assert render(element(view, "#mobile-menu a[href='/devices']")) =~ "phx-click"
      refute render(element(view, "aside.lg\\:flex a[href='/devices']")) =~ "phx-click"
    end
  end

  describe "theme_colors/1" do
    test "a forced theme has a single colour without media query" do
      assert [{_light_color, nil}] = Layouts.theme_colors("light")
      assert [{_dark_color, nil}] = Layouts.theme_colors("dark")
      refute Layouts.theme_colors("light") == Layouts.theme_colors("dark")
    end

    test "auto has one colour per colour scheme" do
      assert [
               {_light_color, "(prefers-color-scheme: light)"},
               {_dark_color, "(prefers-color-scheme: dark)"}
             ] =
               Layouts.theme_colors("auto")
    end
  end

  describe "manifest" do
    test "is served at the root as a standalone application manifest", %{conn: conn} do
      response = get(conn, "/manifest.webmanifest")

      assert response.status == 200
      assert [content_type] = get_resp_header(response, "content-type")
      assert content_type =~ "application/manifest+json"

      manifest = JSON.decode!(response.resp_body)
      assert manifest["display"] == "standalone"
      assert manifest["start_url"] == "/"
      assert manifest["scope"] == "/"

      for icon <- manifest["icons"] do
        assert get(build_conn(), icon["src"]).status == 200
      end

      assert Enum.any?(manifest["icons"], &(&1["purpose"] == "maskable"))
    end
  end

  defp meta_content(document, name), do: attribute(document, ~s(meta[name="#{name}"]), "content")

  defp attribute(document, selector, name) do
    document
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end
end
