defmodule BelgoWeb.Devices.Live.Show do
  @moduledoc "Everything known about a device: placement, interfaces, guests and synced records."

  @behaviour BelgoWeb.Hooks.Discovery
  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Discovery.Correlation
  alias Belgo.Inventory
  alias Belgo.Inventory.Audit
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Snapshot
  alias Belgo.Reachability
  alias Belgo.Reachability.Status
  alias Belgo.Sync.DesiredState
  alias Belgo.Topology.DeviceNode
  alias Belgo.Topology.Physical
  alias Belgo.Topology.Routing
  alias BelgoWeb.Format
  alias BelgoWeb.Live.Mutation

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:device_id, id)
     |> assign(:reachability, nil)
     |> subscribe_reachability(id)
     |> assign_inventory()}
  end

  defp subscribe_reachability(socket, device_id) do
    if connected?(socket), do: Reachability.subscribe(device_id)
    socket
  end

  # Pings on display only (connected), reusing a recent result.
  defp assign_reachability(socket, device) do
    if connected?(socket),
      do: assign(socket, :reachability, Reachability.check(device)),
      else: assign(socket, :reachability, Reachability.status(device.id))
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    snapshot = socket.assigns.snapshot

    case Snapshot.fetch(snapshot, :devices, socket.assigns.device_id) do
      {:ok, device} ->
        socket
        |> assign(:page_title, device.name)
        |> assign(:device, device)
        |> assign_reachability(device)
        |> assign(:path, Physical.device_path(snapshot, device))
        |> assign(:network_by_id, Snapshot.index(snapshot, :networks))
        |> assign(:device_by_id, Snapshot.index(snapshot, :devices))
        |> assign(:guests, DeviceNode.build(device, DeviceNode.guests_by_host(snapshot)).guests)
        |> assign(
          :issues,
          snapshot
          |> Inventory.issues()
          |> Audit.issues_for(:devices, device.id)
        )
        |> assign_discovery()
        |> assign(
          :desired_state,
          snapshot
          |> DesiredState.build()
          |> DesiredState.for_device(device.id)
        )

      {:error, :not_found} ->
        socket
        |> put_flash(:error, gettext("This device no longer exists."))
        |> push_navigate(to: ~p"/devices")
    end
  end

  @impl BelgoWeb.Hooks.Discovery
  def assign_discovery(%{assigns: %{device_id: device_id, discovery: discovery}} = socket) do
    links = Routing.links(socket.assigns.snapshot, discovery.correlation.uplinks)

    socket
    |> assign(
      :divergences,
      Correlation.divergences_for(discovery.correlation, :devices, device_id)
    )
    |> assign(:link, Map.get(links, device_id))
    |> assign(:network_path, Routing.path(socket.assigns.snapshot, links, device_id))
  end

  @impl Phoenix.LiveView
  def handle_info({:reachability_changed, %Status{device_id: device_id} = status}, socket)
      when device_id == socket.assigns.device_id,
      do: {:noreply, assign(socket, :reachability, status)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("ping", _params, socket) do
    {:noreply,
     assign(socket, :reachability, Reachability.check(socket.assigns.device, force: true))}
  end

  def handle_event("push", _params, socket) do
    Belgo.Discovery.push_device(socket.assigns.device.id)

    {:noreply,
     put_flash(socket, :info, gettext("Push started, its result is shown in Discovery."))}
  end

  def handle_event("delete", _params, socket) do
    case Inventory.delete(:devices, socket.assigns.device.id, Mutation.options(socket)) do
      {:ok, device} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} deleted.", name: device.name))
         |> push_navigate(to: ~p"/devices")}

      error ->
        {:noreply, put_flash(socket, :error, Mutation.describe_error(error))}
    end
  end

  @impl Phoenix.LiveView
  def render(%{device: _device} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={@device.name} back={~p"/devices"}>
        <:title_suffix>
          <.reachability_indicator status={@reachability} />
        </:title_suffix>
        <:subtitle>
          <span class="inline-flex flex-wrap items-center gap-2">
            <.badge>{Format.label(@device.kind)}</.badge>
            <.platform_badges platforms={@device.platforms} />
            <span class="font-mono">{Device.hostname(@device)}</span>
          </span>
        </:subtitle>
        <:actions>
          <Form.button
            :if={Enum.any?(@discovery.providers, &(&1.mode == :write))}
            phx-click="push"
            title={gettext("Write its DHCP reservations and DNS names to the providers")}
          >
            <.icon name="hero-arrow-up-tray-mini" class="size-4" /> {gettext("Push")}
          </Form.button>
          <Form.button navigate={~p"/devices/#{@device.id}/edit"}>
            <.icon name="hero-pencil-square-mini" class="size-4" /> {gettext("Edit")}
          </Form.button>
          <Form.button
            variant={:danger}
            phx-click="delete"
            data-confirm={gettext("Delete %{name}?", name: @device.name)}
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
        <div class="space-y-6 lg:col-span-2">
          <.card title={gettext("Interfaces")} padded={false}>
            <.empty_state
              :if={@device.interfaces == []}
              icon="hero-signal"
              title={gettext("No interface")}
            />
            <.table :if={@device.interfaces != []} id="interfaces" rows={@device.interfaces}>
              <:col :let={interface} label={gettext("Interface")}>
                <p class="font-medium">{interface.name || "—"}</p>
                <p class="font-mono text-xs text-muted">{interface.mac}</p>
              </:col>
              <:col :let={interface} label={gettext("Address")}>
                <p class="font-mono">{interface.ip || "—"}</p>
                <p class="text-xs text-muted">{Format.assignment(interface.assignment)}</p>
                <p :for={dns_name <- interface.dns_names} class="font-mono text-xs text-accent">
                  {dns_name}
                </p>
              </:col>
              <:col :let={interface} label={gettext("Network")} class="hidden sm:table-cell">
                {network_name(@network_by_id, interface.network_id)}
              </:col>
              <:col :let={interface} label={gettext("Switch")} class="hidden md:table-cell">
                <.device_link
                  :if={@device_by_id[interface.switch_id]}
                  device={@device_by_id[interface.switch_id]}
                />
                <p :if={interface.switch_port} class="text-xs text-muted">
                  {gettext("Port %{port}", port: interface.switch_port)}
                </p>
              </:col>
            </.table>
          </.card>

          <.card :if={@link} title={gettext("Network")}>
            <.properties>
              <:item label={gettext("Connected to")}>
                <.link
                  :if={@link.switch_id}
                  navigate={~p"/devices/#{@link.switch_id}"}
                  class="hover:text-accent"
                >
                  {@link.switch_name || @link.switch_id}
                </.link>
                <span :if={!@link.switch_id}>{@link.switch_name || "—"}</span>
                <div class="mt-0.5"><.link_details link={@link} /></div>
              </:item>
              <:item label={gettext("Path")}>
                <.network_path hops={@network_path} />
              </:item>
            </.properties>
          </.card>

          <.card :if={@guests != []} title={gettext("Guests")}>
            <.device_tree nodes={@guests} />
          </.card>

          <.card title={gettext("Synchronised records")} padded={false}>
            <.sync_records desired_state={@desired_state} />
          </.card>
        </div>

        <.card title={gettext("Details")} class="self-start">
          <.properties>
            <:item label={gettext("Placement")}>
              <.placement device={@device} path={@path} />
            </:item>
            <:item :if={@device.virtualization} label={gettext("Runs as")}>
              {Format.label(@device.virtualization)}
            </:item>
            <:item :for={entry <- @device.metadata} label={entry.label}>
              {entry.value}
            </:item>
            <:item :if={@device.tags != []} label={gettext("Tags")}>
              <div class="flex flex-wrap gap-1">
                <.badge :for={tag <- @device.tags}>{tag}</.badge>
              </div>
            </:item>
            <:item label={gettext("Identifier")}>
              <span class="font-mono text-xs">{@device.id}</span>
            </:item>
          </.properties>
          <p :if={@device.notes} class="mt-4 text-sm whitespace-pre-line text-muted">
            {@device.notes}
          </p>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns), do: ~H""

  attr(:device, Device, required: true)
  attr(:path, :map, required: true)

  defp placement(assigns) do
    ~H"""
    <%= case Device.placement(@device) do %>
      <% :portable -> %>
        <span class="inline-flex items-center gap-1">
          <.icon name="hero-briefcase-mini" class="size-4 text-muted" /> {gettext("Portable")}
        </span>
      <% :unplaced -> %>
        <span class="text-muted">{gettext("Unplaced")}</span>
      <% _placed -> %>
        <ol class="flex flex-wrap items-center gap-1">
          <li :for={location <- @path.locations} class="inline-flex items-center gap-1">
            <.link navigate={~p"/locations/#{location.id}"} class="hover:text-accent">
              {location.name}
            </.link>
            <.icon name="hero-chevron-right-mini" class="size-4 text-muted" />
          </li>
          <li :for={host <- @path.hosts} class="inline-flex items-center gap-1">
            <.link navigate={~p"/devices/#{host.id}"} class="hover:text-accent">{host.name}</.link>
            <.icon name="hero-chevron-right-mini" class="size-4 text-muted" />
          </li>
          <li class="font-medium">{@device.name}</li>
        </ol>
    <% end %>
    """
  end

  attr(:desired_state, DesiredState, required: true)

  defp sync_records(assigns) do
    ~H"""
    <ul class="divide-y divide-border text-sm">
      <li
        :for={record <- @desired_state.dns_records}
        class="flex items-center justify-between gap-3 px-5 py-2.5"
      >
        <span class="inline-flex items-center gap-2">
          <.badge tone={:accent}>DNS</.badge>
          <span class="font-mono">{record.name}</span>
        </span>
        <span class="font-mono text-muted">{record.address}</span>
      </li>
      <li
        :for={reservation <- @desired_state.dhcp_reservations}
        class="flex items-center justify-between gap-3 px-5 py-2.5"
      >
        <span class="inline-flex items-center gap-2">
          <.badge tone={:success}>DHCP</.badge>
          <span class="font-mono">{reservation.mac}</span>
        </span>
        <span class="font-mono text-muted">{reservation.address}</span>
      </li>
      <li
        :for={client <- @desired_state.client_names}
        class="flex items-center justify-between gap-3 px-5 py-2.5"
      >
        <span class="inline-flex items-center gap-2">
          <.badge>{gettext("Client")}</.badge>
          <span class="font-mono">{client.mac}</span>
        </span>
        <span class="text-muted">{client.name}</span>
      </li>
    </ul>
    <.empty_state
      :if={@desired_state == %DesiredState{}}
      icon="hero-arrow-path"
      title={gettext("Nothing to synchronise")}
    >
      {gettext("Add an interface with a MAC or an IP address.")}
    </.empty_state>
    """
  end

  defp network_name(_network_by_id, nil), do: "—"

  defp network_name(network_by_id, network_id) do
    case Map.fetch(network_by_id, network_id) do
      {:ok, network} -> network.name
      :error -> network_id
    end
  end
end
