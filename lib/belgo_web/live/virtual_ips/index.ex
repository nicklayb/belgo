defmodule BelgoWeb.VirtualIps.Live.Index do
  @moduledoc """
  List of virtual IPs (load balancer and floating addresses), pinged and port checked
  on display: one accepting TCP connections counts as up, even without ping.
  """

  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Inventory
  alias Belgo.Inventory.Snapshot
  alias BelgoWeb.Format
  alias BelgoWeb.Live.Mutation
  alias BelgoWeb.Live.PortScans
  alias BelgoWeb.Live.Reachability
  alias BelgoWeb.VirtualIps.Status

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Virtual IPs"))
     |> Reachability.subscribe()
     |> PortScans.subscribe()
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    snapshot = socket.assigns.snapshot

    socket
    |> assign(:virtual_ips, snapshot.virtual_ips)
    |> assign(:device_by_id, Snapshot.index(snapshot, :devices))
    |> assign(:network_by_id, Snapshot.index(snapshot, :networks))
    |> Reachability.check(Enum.map(snapshot.virtual_ips, & &1.ip))
    |> PortScans.scan(Enum.map(snapshot.virtual_ips, & &1.ip))
  end

  @impl Phoenix.LiveView
  def handle_info({:reachability_changed, address_statuses}, socket),
    do: {:noreply, Reachability.changed(socket, address_statuses)}

  def handle_info({:port_scan_changed, address_scans}, socket),
    do: {:noreply, PortScans.changed(socket, address_scans)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("delete", %{"id" => id}, socket) do
    case Inventory.delete(:virtual_ips, id, Mutation.options(socket)) do
      {:ok, virtual_ip} ->
        {:noreply, put_flash(socket, :info, gettext("%{name} deleted.", name: virtual_ip.name))}

      error ->
        {:noreply, put_flash(socket, :error, Mutation.describe_error(error))}
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
      <.page_header title={gettext("Virtual IPs")}>
        <:subtitle>
          {gettext("Addresses that are not machines: load balancers and floating addresses.")}
        </:subtitle>
        <:actions>
          <Form.button variant={:primary} navigate={~p"/virtual-ips/new"}>
            <.icon name="hero-plus-mini" class="size-4" /> {gettext("New virtual IP")}
          </Form.button>
        </:actions>
      </.page_header>

      <.card padded={false}>
        <.empty_state
          :if={@virtual_ips == []}
          icon="hero-arrows-pointing-in"
          title={gettext("No virtual IP yet")}
        >
          {gettext("Add a MetalLB or kube-vip address to give it DNS names.")}
        </.empty_state>
        <.table
          :if={@virtual_ips != []}
          id="virtual-ips"
          rows={@virtual_ips}
          row_id={&"virtual-ip-#{&1.id}"}
          row_click={&JS.navigate(~p"/virtual-ips/#{&1.id}")}
        >
          <:col :let={virtual_ip} label={gettext("Name")}>
            <p class="flex items-center gap-2 font-medium">
              <.link navigate={~p"/virtual-ips/#{virtual_ip.id}"} class="hover:text-accent">
                {virtual_ip.name}
              </.link>
              <.reachability_indicator status={
                Status.build(@address_statuses, @address_scans, virtual_ip.ip)
              } />
            </p>
            <p class="text-xs text-muted">{Format.label(virtual_ip.kind)}</p>
          </:col>
          <:col :let={virtual_ip} label={gettext("Address")}>
            <p class="font-mono">{virtual_ip.ip}</p>
            <p :if={@network_by_id[virtual_ip.network_id]} class="text-xs text-muted">
              {@network_by_id[virtual_ip.network_id].name}
            </p>
          </:col>
          <:col :let={virtual_ip} label={gettext("Owner")} class="hidden sm:table-cell">
            <.device_link
              :if={@device_by_id[virtual_ip.owner_id]}
              device={@device_by_id[virtual_ip.owner_id]}
            />
            <span :if={!@device_by_id[virtual_ip.owner_id]} class="text-muted">—</span>
          </:col>
          <:col :let={virtual_ip} label={gettext("DNS names")} class="hidden md:table-cell">
            <p :for={name <- Enum.take(virtual_ip.dns_names, 3)} class="font-mono text-xs">{name}</p>
            <p :if={length(virtual_ip.dns_names) > 3} class="text-xs text-muted">
              {gettext("and %{count} more", count: length(virtual_ip.dns_names) - 3)}
            </p>
          </:col>
          <:action :let={virtual_ip}>
            <Form.button
              variant={:ghost}
              size={:small}
              navigate={~p"/virtual-ips/#{virtual_ip.id}/edit"}
            >
              <.icon name="hero-pencil-square-micro" class="size-4" />
              <span class="sr-only">{gettext("Edit")}</span>
            </Form.button>
            <Form.button
              variant={:danger}
              size={:small}
              phx-click="delete"
              phx-value-id={virtual_ip.id}
              data-confirm={gettext("Delete %{name}?", name: virtual_ip.name)}
            >
              <.icon name="hero-trash-micro" class="size-4" />
              <span class="sr-only">{gettext("Delete")}</span>
            </Form.button>
          </:action>
        </.table>
      </.card>
    </Layouts.app>
    """
  end
end
