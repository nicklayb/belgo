defmodule BelgoWeb.Components.Layouts do
  @moduledoc "Page layouts: the root HTML document and the application shell."

  use BelgoWeb, :component

  alias Belgo.Accounts.User
  alias BelgoWeb.Navigation

  # Hex values of the `--color-surface` token (assets/css/app.css), the colour of the
  # mobile header, so the browser chrome around it blends in.
  @light_theme_color "#ffffff"
  @dark_theme_color "#121215"
  @application_title "Belgo"

  embed_templates("layouts/*")

  attr(:theme, :string, default: nil, doc: "`auto` (or nil), `light` or `dark`")

  @doc """
  Head tags letting Belgo run as a standalone application once added to a home screen:
  web manifest (fetched with credentials, behind the forward authentication), Apple
  standalone tags and the theme colour(s) matching the theme setting.
  """
  def standalone_app_meta(assigns) do
    assigns =
      assigns
      |> assign(:theme_colors, theme_colors(assigns.theme))
      |> assign(:application_title, @application_title)

    ~H"""
    <link rel="manifest" href={~p"/manifest.webmanifest"} crossorigin="use-credentials" />
    <meta name="mobile-web-app-capable" content="yes" />
    <meta name="apple-mobile-web-app-capable" content="yes" />
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent" />
    <meta name="apple-mobile-web-app-title" content={@application_title} />
    <meta
      :for={{color, media} <- @theme_colors}
      name="theme-color"
      content={color}
      media={media}
    />
    """
  end

  @doc """
  Theme colours as `{colour, media query or nil}`: a forced theme has one colour, `auto`
  one per colour scheme.
  """
  @spec theme_colors(String.t() | nil) :: [{String.t(), String.t() | nil}]
  def theme_colors("light"), do: [{@light_theme_color, nil}]
  def theme_colors("dark"), do: [{@dark_theme_color, nil}]

  def theme_colors(_auto) do
    [
      {@light_theme_color, "(prefers-color-scheme: light)"},
      {@dark_theme_color, "(prefers-color-scheme: dark)"}
    ]
  end

  attr(:flash, :map, required: true)
  attr(:current_user, User, required: true)
  attr(:current_path, :string, required: true)
  attr(:navigation_badges, :map, default: %{})
  attr(:wide, :boolean, default: false, doc: "uses the whole width (the plan editor)")
  slot(:inner_block, required: true)

  @doc "Application shell: sidebar on large screens, collapsible top bar on small ones."
  def app(assigns) do
    ~H"""
    <div class="flex h-full">
      <aside class="app-chrome hidden w-60 shrink-0 flex-col border-r border-border bg-surface pt-[env(safe-area-inset-top)] pb-[env(safe-area-inset-bottom)] pl-[env(safe-area-inset-left)] lg:flex">
        <.sidebar
          current_user={@current_user}
          current_path={@current_path}
          navigation_badges={@navigation_badges}
        />
      </aside>

      <div class="flex min-w-0 flex-1 flex-col">
        <header class="app-chrome flex items-center justify-between border-b border-border bg-surface pt-[calc(0.75rem+env(safe-area-inset-top))] pr-[max(1rem,env(safe-area-inset-right))] pb-3 pl-[max(1rem,env(safe-area-inset-left))] lg:hidden">
          <.logo />
          <button
            type="button"
            class="rounded-md p-1.5 text-muted hover:bg-surface-muted hover:text-foreground"
            aria-label={gettext("Open menu")}
            phx-click={JS.show(to: "#mobile-menu", display: "flex")}
          >
            <.icon name="hero-bars-3" class="size-6" />
          </button>
        </header>

        <div
          id="mobile-menu"
          class="fixed inset-0 z-40 hidden lg:hidden"
          phx-window-keydown={JS.hide(to: "#mobile-menu")}
          phx-key="Escape"
        >
          <div class="absolute inset-0 bg-black/40" phx-click={JS.hide(to: "#mobile-menu")}></div>
          <aside class="app-chrome relative flex h-full w-72 max-w-[85%] flex-col overscroll-contain bg-surface pt-[env(safe-area-inset-top)] pb-[env(safe-area-inset-bottom)] pl-[env(safe-area-inset-left)] shadow-xl">
            <button
              type="button"
              id="mobile-menu-close"
              class="absolute top-[calc(1rem+env(safe-area-inset-top))] right-3 rounded-md p-1.5 text-muted hover:bg-surface-muted hover:text-foreground"
              aria-label={gettext("Close menu")}
              phx-click={JS.hide(to: "#mobile-menu")}
            >
              <.icon name="hero-x-mark" class="size-6" />
            </button>
            <.sidebar
              current_user={@current_user}
              current_path={@current_path}
              navigation_badges={@navigation_badges}
              on_navigate={JS.hide(to: "#mobile-menu")}
            />
          </aside>
        </div>

        <.live_component module={BelgoWeb.Components.SearchModal} id="global-search" />
        <main class="relative flex flex-1 flex-col overflow-y-auto overscroll-contain pr-[env(safe-area-inset-right)] pl-[env(safe-area-inset-left)] lg:pl-0">
          <div class={[
            "w-full flex-1 px-4 py-6",
            !@wide && "mx-auto max-w-6xl lg:px-8 lg:py-8",
            @wide && "lg:px-6 lg:py-4"
          ]}>
            <.flash_group flash={@flash} />
            {render_slot(@inner_block)}
          </div>
          <.version_footer />
        </main>
      </div>
    </div>
    """
  end

  @doc "Discreet footer showing the application version, aligned to the bottom right."
  def version_footer(assigns) do
    assigns = assign(assigns, :version, Belgo.version())

    ~H"""
    <footer
      id="version-footer"
      class="shrink-0 px-4 pb-[calc(0.75rem+env(safe-area-inset-bottom))] text-right text-xs text-muted lg:px-8"
    >
      v{@version}
    </footer>
    """
  end

  attr(:current_user, User, required: true)
  attr(:current_path, :string, required: true)
  attr(:navigation_badges, :map, required: true)
  attr(:on_navigate, JS, default: nil, doc: "run when a link is tapped (closes the drawer)")

  defp sidebar(assigns) do
    assigns = assign(assigns, :sections, Navigation.sections())

    ~H"""
    <div class="px-5 py-5"><.logo /></div>
    <div class="px-3 pb-3">
      <button
        type="button"
        data-search-open
        phx-click={@on_navigate}
        class="flex w-full items-center gap-2 rounded-md px-3 py-2 text-sm text-muted ring-1 ring-border ring-inset hover:text-foreground"
      >
        <.icon name="hero-magnifying-glass-mini" class="size-4" />
        <span class="flex-1 text-left">{gettext("Search")}</span>
        <kbd
          data-shortcut-hint
          class="rounded border border-border px-1 font-sans text-xs pointer-coarse:hidden"
        >
          ⌘K
        </kbd>
      </button>
    </div>
    <nav class="flex-1 space-y-4 overflow-y-auto px-3">
      <div :for={section <- @sections} class="space-y-0.5">
        <p
          :if={section.title}
          class="px-3 pb-1 text-xs font-medium tracking-wide text-muted uppercase"
        >
          {section.title}
        </p>
        <.link
          :for={item <- section.items}
          navigate={item.path}
          phx-click={@on_navigate}
          class={[
            "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors",
            if(Navigation.active?(item, @current_path),
              do: "bg-accent-soft text-accent",
              else: "text-muted hover:bg-surface-muted hover:text-foreground"
            )
          ]}
        >
          <.icon name={item.icon} class="size-5" />
          <span class="flex-1">{item.label}</span>
          <span
            :for={{badge, count} <- Navigation.badge_counts(item, @navigation_badges)}
            data-badge={badge}
            title={Navigation.badge_label(badge)}
            class={[
              "min-w-5 rounded-full px-1.5 text-center text-xs leading-5 font-semibold tabular-nums",
              badge == :overview && "bg-warning text-white",
              badge != :overview && "bg-accent text-accent-foreground"
            ]}
            aria-label={
              gettext("%{label}: %{count}", label: Navigation.badge_label(badge), count: count)
            }
          >
            {count}
          </span>
        </.link>
      </div>
    </nav>
    <.link
      navigate={~p"/settings"}
      phx-click={@on_navigate}
      data-user-settings
      title={gettext("Settings")}
      class={[
        "flex items-center gap-3 border-t border-border px-5 py-4 text-sm hover:bg-surface-muted",
        @current_path == "/settings" && "bg-accent-soft"
      ]}
    >
      <.icon name="hero-user-circle" class="size-6 text-muted" />
      <div class="min-w-0 flex-1">
        <p class="truncate font-medium">{User.display_name(@current_user)}</p>
        <p :if={@current_user.email} class="truncate text-xs text-muted">{@current_user.email}</p>
      </div>
      <.icon name="hero-cog-6-tooth-mini" class="size-4 text-muted" />
    </.link>
    """
  end

  @doc "Belgo wordmark."
  def logo(assigns) do
    ~H"""
    <.link navigate={~p"/"} class="flex items-center gap-2 text-lg font-semibold tracking-tight">
      <span class="grid size-7 place-items-center rounded-md bg-accent text-accent-foreground">
        <.icon name="hero-cube-transparent-mini" class="size-5" />
      </span>
      Belgo
    </.link>
    """
  end
end
