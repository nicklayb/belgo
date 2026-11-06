defmodule BelgoWeb.Locations.Live.Show do
  @moduledoc "A location: where it is, what it contains and every device inside it."

  @behaviour BelgoWeb.Hooks.Discovery
  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Discovery.Correlation
  alias Belgo.Inventory
  alias Belgo.Inventory.Audit
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Snapshot
  alias Belgo.Topology.Physical
  alias BelgoWeb.Format
  alias BelgoWeb.Live.Mutation

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:location_id, id)
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    snapshot = socket.assigns.snapshot

    case Snapshot.fetch(snapshot, :locations, socket.assigns.location_id) do
      {:ok, location} ->
        placements = Physical.devices_within(snapshot, location.id)

        socket
        |> assign(:page_title, location.name)
        |> assign(:location, location)
        |> assign(:ancestors, ancestors(snapshot, location))
        |> assign(:placements, placements)
        |> assign(:device_count_by_child, device_count_by_child(placements))
        |> assign(:children, Physical.children(snapshot, location.id))
        |> assign(
          :issues,
          snapshot
          |> Inventory.issues()
          |> Audit.issues_for(:locations, location.id)
        )
        |> assign_discovery()

      {:error, :not_found} ->
        socket
        |> put_flash(:error, gettext("This location no longer exists."))
        |> push_navigate(to: ~p"/locations")
    end
  end

  @impl BelgoWeb.Hooks.Discovery
  def assign_discovery(%{assigns: %{location_id: location_id, discovery: discovery}} = socket) do
    assign(
      socket,
      :divergences,
      Correlation.divergences_for(discovery.correlation, :locations, location_id)
    )
  end

  def assign_discovery(socket), do: socket

  @impl Phoenix.LiveView
  def handle_event("delete", _params, socket) do
    case Inventory.delete(:locations, socket.assigns.location.id, Mutation.options(socket)) do
      {:ok, location} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} deleted.", name: location.name))
         |> push_navigate(to: ~p"/locations")}

      error ->
        {:noreply, put_flash(socket, :error, Mutation.describe_error(error))}
    end
  end

  defp ancestors(snapshot, location) do
    snapshot
    |> Physical.path(location.id)
    |> Enum.reject(&(&1.id == location.id))
  end

  defp device_count_by_child(placements) do
    placements
    |> Enum.flat_map(fn placement -> Enum.take(placement.locations, 1) end)
    |> Enum.frequencies_by(& &1.id)
  end

  @impl Phoenix.LiveView
  def render(%{location: _location} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={@location.name} back={~p"/locations"}>
        <:subtitle>
          <span class="inline-flex flex-wrap items-center gap-2">
            <.badge>{Format.label(@location.kind)}</.badge>
            <ol :if={@ancestors != []} class="flex flex-wrap items-center gap-1">
              <li :for={ancestor <- @ancestors} class="inline-flex items-center gap-1">
                <.link navigate={~p"/locations/#{ancestor.id}"} class="hover:text-accent">
                  {ancestor.name}
                </.link>
                <.icon name="hero-chevron-right-mini" class="size-4 text-muted" />
              </li>
            </ol>
          </span>
        </:subtitle>
        <:actions>
          <Form.button navigate={~p"/locations/new?parent_id=#{@location.id}"}>
            <.icon name="hero-plus-mini" class="size-4" /> {gettext("Add inside")}
          </Form.button>
          <Form.button navigate={~p"/locations/#{@location.id}/edit"}>
            <.icon name="hero-pencil-square-mini" class="size-4" /> {gettext("Edit")}
          </Form.button>
          <Form.button
            variant={:danger}
            phx-click="delete"
            data-confirm={gettext("Delete %{name}?", name: @location.name)}
          >
            <.icon name="hero-trash-mini" class="size-4" /> {gettext("Delete")}
          </Form.button>
        </:actions>
      </.page_header>

      <.card :if={@issues != []} class="mb-6 border-warning/40" padded={false}>
        <.issue_list issues={@issues} />
      </.card>

      <.card
        :if={@divergences != []}
        title={gettext("Divergences with providers")}
        class="mb-6 border-warning/40"
        padded={false}
      >
        <.divergence_list divergences={@divergences} />
      </.card>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <.card title={gettext("Devices")} class="min-w-0 lg:col-span-2" padded={false}>
          <:actions>
            <.badge>{length(@placements)}</.badge>
          </:actions>
          <.empty_state
            :if={@placements == []}
            icon="hero-server"
            title={gettext("No device here")}
          >
            {gettext("Devices placed here or in a sub-location are listed here.")}
          </.empty_state>
          <.table :if={@placements != []} id="location-devices" rows={@placements}>
            <:col :let={placement} label={gettext("Device")}>
              <.device_link device={placement.device} />
              <p class="text-xs text-muted">
                {Format.label(placement.device.virtualization || placement.device.kind)}
              </p>
            </:col>
            <:col :let={placement} label={gettext("Where")} class="hidden sm:table-cell">
              <.relative_place placement={placement} />
            </:col>
            <:col :let={placement} label={gettext("Addresses")} class="hidden md:table-cell">
              <p :for={ip <- Device.ip_addresses(placement.device)} class="font-mono text-xs">
                {ip}
              </p>
              <span :if={Device.ip_addresses(placement.device) == []} class="text-muted">—</span>
            </:col>
          </.table>
        </.card>

        <div class="min-w-0 space-y-6 self-start">
          <.card :if={@children != []} title={gettext("Inside")} padded={false}>
            <ul class="divide-y divide-border text-sm">
              <li :for={child <- @children}>
                <.link
                  navigate={~p"/locations/#{child.id}"}
                  class="flex items-center gap-2 px-5 py-2.5 hover:bg-surface-muted/60"
                >
                  <.icon name={Format.location_icon(child)} class="size-4 text-accent" />
                  <span class="flex-1 font-medium">{child.name}</span>
                  <.badge :if={@device_count_by_child[child.id]}>
                    {@device_count_by_child[child.id]}
                  </.badge>
                </.link>
              </li>
            </ul>
          </.card>

          <.card title={gettext("Details")}>
            <.properties>
              <:item label={gettext("Kind")}>{Format.label(@location.kind)}</:item>
              <:item :if={@location.home_assistant_id} label={gettext("Home Assistant")}>
                <span class="font-mono text-xs">{@location.home_assistant_id}</span>
              </:item>
              <:item label={gettext("Identifier")}>
                <span class="font-mono text-xs">{@location.id}</span>
              </:item>
            </.properties>
            <p :if={@location.notes} class="mt-4 text-sm whitespace-pre-line text-muted">
              {@location.notes}
            </p>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns), do: ~H""

  attr(:placement, Physical.DevicePlacement, required: true)

  defp relative_place(assigns) do
    ~H"""
    <div class="space-y-0.5">
      <p :if={@placement.locations == []} class="text-muted">{gettext("Here")}</p>
      <p :if={@placement.locations != []} class="flex flex-wrap items-center gap-1">
        <%= for {location, position} <- Enum.with_index(@placement.locations) do %>
          <.icon :if={position > 0} name="hero-chevron-right-micro" class="size-3 text-muted" />
          <.link navigate={~p"/locations/#{location.id}"} class="hover:text-accent">
            {location.name}
          </.link>
        <% end %>
      </p>
      <p :if={@placement.hosts != []} class="text-xs text-muted">
        {gettext("on %{hosts}", hosts: Enum.map_join(@placement.hosts, " › ", & &1.name))}
      </p>
    </div>
    """
  end
end
