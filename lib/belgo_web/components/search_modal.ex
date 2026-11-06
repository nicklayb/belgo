defmodule BelgoWeb.Components.SearchModal do
  @moduledoc """
  The global search: opened from the sidebar field or with Ctrl/⌘+K, closed with
  Escape or a click outside. Searches the known devices, and the discovery when
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

  @shortcut_key "k"

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, assign(socket, open?: false, query: "", include_discovery?: false, results: [])}
  end

  @impl Phoenix.LiveComponent
  def handle_event("open", _params, socket), do: {:noreply, assign(socket, :open?, true)}
  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :open?, false)}

  def handle_event("shortcut", %{"key" => @shortcut_key} = params, socket) do
    if params["ctrl_key"] || params["meta_key"],
      do: {:noreply, assign(socket, :open?, true)},
      else: {:noreply, socket}
  end

  def handle_event("shortcut", _params, socket), do: {:noreply, socket}

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

  defp result_path(%Search.Result{type: :discovered, id: id}),
    do: ~p"/devices/new?discovered=#{id}"

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id} phx-window-keydown="shortcut" phx-key="k" phx-target={@myself}>
      <div
        :if={@open?}
        class="fixed inset-0 z-50 flex items-start justify-center bg-black/40 p-4 pt-[10vh]"
        phx-window-keydown="close"
        phx-key="Escape"
        phx-target={@myself}
      >
        <div class="absolute inset-0" phx-click="close" phx-target={@myself}></div>
        <div class="relative w-full max-w-2xl overflow-hidden rounded-xl border border-border bg-surface shadow-2xl">
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
                phx-mounted={JS.focus()}
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
          <ul :if={@results != []} class="max-h-[60vh] divide-y divide-border overflow-y-auto">
            <li :for={result <- @results}>
              <.link
                navigate={result_path(result)}
                phx-click="close"
                phx-target={@myself}
                class="flex items-center justify-between gap-3 px-4 py-2.5 hover:bg-surface-muted"
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
      </div>
    </div>
    """
  end
end
