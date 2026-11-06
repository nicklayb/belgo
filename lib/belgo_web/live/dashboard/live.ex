defmodule BelgoWeb.Dashboard.Live do
  @moduledoc "Overview: key figures and the issues of the inventory."

  @behaviour BelgoWeb.Hooks.Discovery
  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Discovery.Correlation
  alias Belgo.Inventory
  alias Belgo.Inventory.Snapshot
  alias Belgo.Sync.DesiredState
  alias Belgo.Topology.Hosting
  alias BelgoWeb.Format

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Overview"))
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    snapshot = socket.assigns.snapshot

    socket
    |> assign(:issues, Inventory.issues(snapshot))
    |> assign_discovery()
    |> assign(
      :host_count,
      snapshot
      |> Hosting.build()
      |> length()
    )
    |> assign(
      :dns_record_count,
      snapshot
      |> DesiredState.build()
      |> Map.fetch!(:dns_records)
      |> length()
    )
  end

  @impl BelgoWeb.Hooks.Discovery
  def assign_discovery(%{assigns: %{discovery: discovery, snapshot: snapshot}} = socket) do
    correlation = discovery.correlation

    socket
    |> assign(:divergence_groups, divergence_groups(correlation.divergences, snapshot))
    |> assign(:conflicts, Correlation.unowned_conflicts(correlation))
    |> assign(:divergence_count, length(correlation.divergences))
  end

  defp divergence_groups(divergences, snapshot) do
    divergences
    |> Enum.group_by(&{&1.collection, &1.id})
    |> Enum.sort()
    |> Enum.map(fn {{collection, id} = record, record_divergences} ->
      name =
        case Snapshot.fetch(snapshot, collection, id) do
          {:ok, found} -> found.name
          {:error, :not_found} -> id
        end

      {record, name, record_divergences}
    end)
  end

  defp record_path({:devices, id}), do: ~p"/devices/#{id}"
  defp record_path({:networks, id}), do: ~p"/networks/#{id}/edit"
  defp record_path({:locations, id}), do: ~p"/locations/#{id}"

  @impl Phoenix.LiveView
  def handle_event("reload", _params, socket) do
    case Inventory.reload() do
      :ok ->
        {:noreply, put_flash(socket, :info, gettext("Inventory reloaded from disk."))}

      {:error, {:invalid_inventory, messages}} ->
        message = Enum.join([gettext("The files are invalid, nothing changed:") | messages], "\n")
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={gettext("Overview")}>
        <:subtitle>{gettext("Your homelab at a glance.")}</:subtitle>
        <:actions>
          <Form.button phx-click="reload" title={gettext("Re-read the inventory files")}>
            <.icon name="hero-arrow-path-mini" class="size-4" /> {gettext("Reload files")}
          </Form.button>
        </:actions>
      </.page_header>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <.stat
          label={gettext("Devices")}
          value={length(@snapshot.devices)}
          icon="hero-server"
          navigate={~p"/devices"}
        />
        <.stat
          label={gettext("Locations")}
          value={length(@snapshot.locations)}
          icon="hero-map-pin"
          navigate={~p"/locations"}
        />
        <.stat
          label={gettext("Hosts")}
          value={@host_count}
          icon="hero-rectangle-stack"
          navigate={~p"/hosting"}
        />
        <.stat
          label={gettext("DNS records")}
          value={@dns_record_count}
          icon="hero-arrow-path"
          navigate={~p"/sync"}
        />
      </div>

      <.card title={gettext("Issues")} class="mt-6" padded={false}>
        <:actions>
          <.badge tone={
            if @issues == [] and @divergence_count == 0 and @conflicts == [],
              do: :success,
              else: :warning
          }>
            {length(@issues) + @divergence_count + length(@conflicts)}
          </.badge>
        </:actions>
        <.empty_state
          :if={@issues == [] and @divergence_count == 0 and @conflicts == []}
          icon="hero-check-circle"
          title={gettext("All consistent")}
        >
          {gettext(
            "No conflicting address, dangling reference, cycle or divergence with the providers."
          )}
        </.empty_state>
        <.issue_list :if={@issues != []} issues={@issues} snapshot={@snapshot} />
        <div :if={@divergence_groups != []} class="border-t border-border first:border-0">
          <p class="px-5 pt-3 text-xs font-medium tracking-wide text-muted uppercase">
            {gettext("Divergences with providers")}
          </p>
          <div :for={{record, name, divergences} <- @divergence_groups}>
            <.link
              navigate={record_path(record)}
              class="block px-5 pt-3 text-sm font-medium hover:text-accent"
            >
              {name}
            </.link>
            <.divergence_list divergences={divergences} />
          </div>
        </div>
        <div :if={@conflicts != []} class="border-t border-border first:border-0">
          <p class="px-5 pt-3 text-xs font-medium tracking-wide text-muted uppercase">
            {gettext("Duplicates on providers")}
          </p>
          <ul class="divide-y divide-border text-sm">
            <li :for={conflict <- @conflicts} class="flex items-start gap-3 px-5 py-3">
              <.icon name="hero-document-duplicate-mini" class="mt-0.5 size-4 shrink-0 text-warning" />
              <div class="min-w-0">
                <.badge>{Format.label(conflict.provider)}</.badge>
                <span class="ml-1">{conflict.message}</span>
              </div>
            </li>
          </ul>
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
