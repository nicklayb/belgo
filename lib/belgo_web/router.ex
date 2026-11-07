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
    plug(BelgoWeb.Plugs.Theme)
    plug(BelgoWeb.Plugs.Locale)
  end

  scope "/", BelgoWeb do
    get("/health", Health.Controller, :show)
  end

  # Discovery is now part of the Overview: former links keep working.
  scope "/", BelgoWeb do
    pipe_through(:browser)
    get("/discovery", Redirect.Controller, :overview)
  end

  scope "/", BelgoWeb do
    pipe_through(:browser)

    live_session :authenticated,
      on_mount: [
        BelgoWeb.Hooks.Locale,
        BelgoWeb.Hooks.Authenticated,
        BelgoWeb.Hooks.CurrentPath,
        BelgoWeb.Hooks.Inventory,
        BelgoWeb.Hooks.Discovery,
        BelgoWeb.Hooks.Notifications
      ] do
      live("/", Dashboard.Live, :show)

      live("/settings", Settings.Live, :show)
      live("/discovery/dns-names/:id", Discovery.Live.ClaimDnsName, :new)

      live("/devices", Devices.Live.Index, :index)
      live("/devices/new", Devices.Live.Form, :new)
      live("/devices/bulk-edit", Devices.Live.BulkEdit, :edit)
      live("/devices/:id", Devices.Live.Show, :show)
      live("/devices/:id/edit", Devices.Live.Form, :edit)

      live("/locations", Locations.Live.Index, :index)
      live("/locations/new", Locations.Live.Form, :new)
      live("/locations/:id", Locations.Live.Show, :show)
      live("/locations/:id/edit", Locations.Live.Form, :edit)

      live("/plan", Plans.Live, :show)
      live("/plan/new", Plans.Editor, :new)
      live("/plan/:id", Plans.Live, :show)
      live("/plan/:id/edit", Plans.Editor, :edit)

      live("/hosting", Hosting.Live, :show)
      live("/routing", Routing.Live, :show)

      live("/virtual-ips", VirtualIps.Live.Index, :index)
      live("/virtual-ips/new", VirtualIps.Live.Form, :new)
      live("/virtual-ips/:id", VirtualIps.Live.Show, :show)
      live("/virtual-ips/:id/edit", VirtualIps.Live.Form, :edit)

      live("/networks", Networks.Live.Index, :index)
      live("/networks/new", Networks.Live.Form, :new)
      live("/networks/:id", Networks.Live.Show, :show)
      live("/networks/:id/edit", Networks.Live.Form, :edit)

      live("/sync", Sync.Live, :show)
    end
  end
end
