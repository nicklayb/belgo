defmodule BelgoWeb.Components.Layouts do
  @moduledoc "Page layouts: the root HTML document and the application shell."

  use BelgoWeb, :component

  alias Belgo.Accounts.User
  alias BelgoWeb.Navigation

  embed_templates("layouts/*")

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
      <aside class="hidden w-60 shrink-0 flex-col border-r border-border bg-surface lg:flex">
        <.sidebar
          current_user={@current_user}
          current_path={@current_path}
          navigation_badges={@navigation_badges}
        />
      </aside>

      <div class="flex min-w-0 flex-1 flex-col">
        <header class="flex items-center justify-between border-b border-border bg-surface px-4 py-3 lg:hidden">
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
          <aside class="relative flex w-64 flex-col bg-surface shadow-xl">
            <.sidebar
              current_user={@current_user}
              current_path={@current_path}
              navigation_badges={@navigation_badges}
            />
          </aside>
        </div>

        <.live_component module={BelgoWeb.Components.SearchModal} id="global-search" />
        <main class="relative flex-1 overflow-y-auto overscroll-contain">
          <div class={[
            "px-4 py-6",
            !@wide && "mx-auto max-w-6xl lg:px-8 lg:py-8",
            @wide && "lg:px-6 lg:py-4"
          ]}>
            <.flash_group flash={@flash} />
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>
    """
  end

  attr(:current_user, User, required: true)
  attr(:current_path, :string, required: true)
  attr(:navigation_badges, :map, required: true)

  defp sidebar(assigns) do
    assigns = assign(assigns, :items, Navigation.items())

    ~H"""
    <div class="px-5 py-5"><.logo /></div>
    <div class="px-3 pb-3">
      <button
        type="button"
        data-search-open
        class="flex w-full items-center gap-2 rounded-md px-3 py-2 text-sm text-muted ring-1 ring-border ring-inset hover:text-foreground"
      >
        <.icon name="hero-magnifying-glass-mini" class="size-4" />
        <span class="flex-1 text-left">{gettext("Search")}</span>
        <kbd class="rounded border border-border px-1 font-sans text-xs">⌘K</kbd>
      </button>
    </div>
    <nav class="flex-1 space-y-0.5 px-3">
      <.link
        :for={item <- @items}
        navigate={item.path}
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
          :for={count <- List.wrap(Navigation.badge_count(item, @navigation_badges))}
          class="min-w-5 rounded-full bg-accent px-1.5 text-center text-xs leading-5 font-semibold text-accent-foreground tabular-nums"
          aria-label={gettext("%{label}: %{count}", label: item.label, count: count)}
        >
          {count}
        </span>
      </.link>
    </nav>
    <div class="flex items-center gap-3 border-t border-border px-5 py-4 text-sm">
      <.icon name="hero-user-circle" class="size-6 text-muted" />
      <div class="min-w-0">
        <p class="truncate font-medium">{User.display_name(@current_user)}</p>
        <p :if={@current_user.email} class="truncate text-xs text-muted">{@current_user.email}</p>
      </div>
    </div>
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
