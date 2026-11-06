defmodule BelgoWeb.Components.SearchModal do
  @moduledoc """
  The global search: a native `<dialog>` opened in the browser (`SearchDialog` hook)
  from any `[data-search-open]` element or with Ctrl/⌘+K, closed with Escape, a click
  outside or a result. Opening and focusing the field happen in the click / key
  handler itself (no server round trip), which browsers such as Safari require to
  focus a field. Arrow keys move through the results, Enter follows the selected
  one (the first by default). Searches the known devices, and the discovery when
  "Include discovery" is checked. Reads the current snapshot and discovery on each
  search, so it needs nothing from the page it is rendered in.
  """

  use Phoenix.LiveComponent
  use Gettext, backend: BelgoWeb.Gettext
  use BelgoWeb, :verified_routes

  import BelgoWeb.Components.Core

  alias Belgo.Discovery
  alias Belgo.Inventory
  alias Belgo.Search
  alias Phoenix.LiveView.JS

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, assign(socket, query: "", include_discovery?: false, results: [])}
  end

  @impl Phoenix.LiveComponent
  def handle_event("search", %{"search" => params}, socket) do
    query = Map.get(params, "query", "")
    include_discovery? = Map.get(params, "include_discovery") == "true"

    {:noreply,
     socket
     |> assign(query: query, include_discovery?: include_discovery?)
     |> assign(:results, search(query, include_discovery?))}
  end

  defp search(query, include_discovery?) do
    options = if include_discovery?, do: [discovery: Discovery.state().correlation], else: []
    Search.run(Inventory.snapshot(), query, options)
  end

  defp result_path(%Search.Result{type: :device, id: id}), do: ~p"/devices/#{id}"
  defp result_path(%Search.Result{type: :virtual_ip, id: id}), do: ~p"/virtual-ips/#{id}"

  defp result_path(%Search.Result{type: :discovered, id: id}),
    do: ~p"/devices/new?discovered=#{id}"

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <dialog
        id="search-dialog"
        phx-hook="SearchDialog"
        phx-mounted={JS.ignore_attributes("open")}
        aria-label={gettext("Search")}
        class="mx-auto mt-[10vh] w-[calc(100%-2rem)] max-w-2xl overflow-hidden rounded-xl border border-border bg-surface p-0 text-foreground shadow-2xl backdrop:bg-black/40"
      >
        <div>
          <.form for={%{}} as={:search} phx-change="search" phx-submit="search" phx-target={@myself}>
            <div class="flex items-center gap-3 border-b border-border px-4">
              <.icon name="hero-magnifying-glass" class="size-5 text-muted" />
              <input
                id="search-input"
                type="text"
                name="search[query]"
                value={@query}
                placeholder={gettext("Name, MAC, IP, DNS name, serial number…")}
                autocomplete="off"
                phx-debounce="100"
                autofocus
                class="w-full border-0 bg-transparent py-3 text-base focus:ring-0 focus:outline-none"
              />
            </div>
            <label class="flex items-center gap-2 border-b border-border px-4 py-2 text-sm text-muted">
              <input type="hidden" name="search[include_discovery]" value="false" />
              <input
                type="checkbox"
                name="search[include_discovery]"
                value="true"
                checked={@include_discovery?}
                class="size-4 rounded border-border"
              />
              {gettext("Include discovery")}
            </label>
          </.form>
          <ul
            :if={@results != []}
            id="search-results"
            role="listbox"
            class="max-h-[60vh] divide-y divide-border overflow-y-auto"
          >
            <li :for={result <- @results}>
              <.link
                navigate={result_path(result)}
                data-search-result
                role="option"
                class="flex items-center justify-between gap-3 px-4 py-2.5 hover:bg-surface-muted data-active:bg-surface-muted data-active:ring-2 data-active:ring-inset data-active:ring-accent"
              >
                <span class="min-w-0">
                  <span class="block truncate font-medium">{result.title}</span>
                  <span class="block truncate text-xs text-muted">
                    {result.field}: <span class="font-mono">{result.value}</span>
                  </span>
                </span>
                <.badge :if={result.type == :discovered} tone={:accent}>
                  {gettext("Discovered")}
                </.badge>
                <.badge :if={result.type == :virtual_ip}>{gettext("Virtual IP")}</.badge>
              </.link>
            </li>
          </ul>
          <p :if={@results == [] and @query != ""} class="px-4 py-6 text-center text-sm text-muted">
            {gettext("Nothing found.")}
          </p>
          <p :if={@query == ""} class="px-4 py-6 text-center text-sm text-muted">
            {gettext("Search devices by almost anything.")}
          </p>
        </div>
      </dialog>
    </div>
    """
  end
end
