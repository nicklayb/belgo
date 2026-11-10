defmodule BelgoWeb do
  @moduledoc """
  Shared `use` macros of the web layer.

      use BelgoWeb, :live_view
  """

  @doc "Paths served as static files."
  def static_paths,
    do: ~w(assets fonts images favicon.ico favicon.svg apple-touch-icon.png robots.txt)

  @doc """
  Name prefixes of the files served at the root, so their digested versions
  (`favicon-<hash>.svg`) are served too.
  """
  def static_file_prefixes, do: ~w(favicon apple-touch-icon robots)

  @doc false
  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  @doc false
  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]
      use Gettext, backend: BelgoWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  @doc false
  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: BelgoWeb.Endpoint,
        router: BelgoWeb.Router,
        statics: BelgoWeb.static_paths()
    end
  end

  @doc false
  def component do
    quote do
      use Phoenix.Component

      unquote(view_helpers())
    end
  end

  @doc false
  def live_view do
    quote do
      use Phoenix.LiveView

      alias BelgoWeb.Components.Layouts

      unquote(view_helpers())
    end
  end

  @doc false
  def view_helpers do
    quote do
      use BelgoWeb.Gettext

      import BelgoWeb.Components.Core
      import BelgoWeb.Components.Discovery
      import BelgoWeb.Components.Inventory
      import BelgoWeb.Components.Routing

      alias BelgoWeb.Components.Form
      alias Phoenix.LiveView.JS

      unquote(verified_routes())
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
