defmodule BelgoWeb.Router do
  use BelgoWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {BelgoWeb.Components.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(BelgoWeb.Plugs.Authenticate)
  end

  scope "/", BelgoWeb do
    get("/health", Health.Controller, :show)
  end

  scope "/", BelgoWeb do
    pipe_through(:browser)

    live_session :authenticated,
      on_mount: [
        BelgoWeb.Hooks.Authenticated,
        BelgoWeb.Hooks.CurrentPath,
        BelgoWeb.Hooks.Inventory,
        BelgoWeb.Hooks.Discovery
      ] do
      live("/", Dashboard.Live, :show)

      live("/discovery", Discovery.Live, :show)

      live("/devices", Devices.Live.Index, :index)
      live("/devices/new", Devices.Live.Form, :new)
      live("/devices/bulk-edit", Devices.Live.BulkEdit, :edit)
      live("/devices/:id", Devices.Live.Show, :show)
      live("/devices/:id/edit", Devices.Live.Form, :edit)

      live("/locations", Locations.Live.Index, :index)
      live("/locations/new", Locations.Live.Form, :new)
      live("/locations/:id", Locations.Live.Show, :show)
      live("/locations/:id/edit", Locations.Live.Form, :edit)

      live("/hosting", Hosting.Live, :show)
      live("/routing", Routing.Live, :show)

      live("/networks", Networks.Live.Index, :index)
      live("/networks/new", Networks.Live.Form, :new)
      live("/networks/:id/edit", Networks.Live.Form, :edit)

      live("/sync", Sync.Live, :show)
    end
  end
end
