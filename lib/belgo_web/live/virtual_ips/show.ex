defmodule BelgoWeb.VirtualIps.Live.Show do
  @moduledoc """
  A virtual IP: its address, owner, DNS names (synchronised as Unbound host
  overrides), whether it answers and which ports it exposes.
  """

  @behaviour BelgoWeb.Hooks.Discovery
  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Discovery.Correlation
  alias Belgo.Inventory
  alias Belgo.Inventory.Audit
  alias Belgo.Inventory.Snapshot
  alias Belgo.Sync.DesiredState
  alias BelgoWeb.Format
  alias BelgoWeb.Live.Mutation
  alias BelgoWeb.Live.PortScans
  alias BelgoWeb.Live.Reachability
  alias BelgoWeb.VirtualIps.Status

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:virtual_ip_id, id)
     |> Reachability.subscribe()
     |> PortScans.subscribe()
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    snapshot = socket.assigns.snapshot

    case Snapshot.fetch(snapshot, :virtual_ips, socket.assigns.virtual_ip_id) do
      {:ok, virtual_ip} ->
        socket
        |> assign(:page_title, virtual_ip.name)
        |> assign(:virtual_ip, virtual_ip)
        |> assign(:owner, owner(snapshot, virtual_ip))
        |> assign(:network, network(snapshot, virtual_ip))
        |> assign(
          :issues,
          snapshot
          |> Inventory.issues()
          |> Audit.issues_for(:virtual_ips, virtual_ip.id)
        )
        |> assign(
          :dns_records,
          snapshot
          |> DesiredState.build()
          |> DesiredState.for_owner({:virtual_ips, virtual_ip.id})
          |> Map.fetch!(:dns_records)
        )
        |> Reachability.check([virtual_ip.ip])
        |> PortScans.scan([virtual_ip.ip])
        |> assign_discovery()

      {:error, :not_found} ->
        socket
        |> put_flash(:error, gettext("This virtual IP no longer exists."))
        |> push_navigate(to: ~p"/virtual-ips")
    end
  end

  @impl BelgoWeb.Hooks.Discovery
  def assign_discovery(%{assigns: %{virtual_ip_id: id, discovery: discovery}} = socket) do
    assign(
      socket,
      :divergences,
      Correlation.divergences_for(discovery.correlation, :virtual_ips, id)
    )
  end

  @impl Phoenix.LiveView
  def handle_info({:reachability_changed, address_statuses}, socket),
    do: {:noreply, Reachability.changed(socket, address_statuses)}

  def handle_info({:port_scan_changed, address_scans}, socket),
    do: {:noreply, PortScans.changed(socket, address_scans)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("ping", _params, socket),
    do: {:noreply, Reachability.check(socket, [socket.assigns.virtual_ip.ip], force: true)}

  def handle_event("refresh-ports", _params, socket),
    do: {:noreply, PortScans.scan(socket, [socket.assigns.virtual_ip.ip], force: true)}

  def handle_event("push", _params, socket) do
    Belgo.Discovery.push_virtual_ip(socket.assigns.virtual_ip.id)

    {:noreply,
     put_flash(socket, :info, gettext("Push started, its result is shown in Discovery."))}
  end

  def handle_event("delete", _params, socket) do
    case Inventory.delete(:virtual_ips, socket.assigns.virtual_ip.id, Mutation.options(socket)) do
      {:ok, virtual_ip} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} deleted.", name: virtual_ip.name))
         |> push_navigate(to: ~p"/virtual-ips")}

      error ->
        {:noreply, put_flash(socket, :error, Mutation.describe_error(error))}
    end
  end

  defp owner(_snapshot, %{owner_id: nil}), do: nil

  defp owner(snapshot, virtual_ip) do
    case Snapshot.fetch(snapshot, :devices, virtual_ip.owner_id) do
      {:ok, device} -> device
      {:error, :not_found} -> nil
    end
  end

  defp network(snapshot, virtual_ip) do
    Enum.find(snapshot.networks, &(&1.id == virtual_ip.network_id)) ||
      Enum.find(snapshot.networks, &Belgo.Inventory.Network.contains?(&1, virtual_ip.ip))
  end

  @impl Phoenix.LiveView
  def render(%{virtual_ip: _virtual_ip} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={@virtual_ip.name} back={~p"/virtual-ips"}>
        <:title_suffix>
          <.reachability_indicator
            id="reachability"
            clickable
            status={Status.build(@address_statuses, @address_scans, @virtual_ip.ip)}
          />
        </:title_suffix>
        <:subtitle>
          <span class="inline-flex flex-wrap items-center gap-2">
            <.badge>{gettext("Virtual IP")}</.badge>
            <.badge tone={:accent}>{Format.label(@virtual_ip.kind)}</.badge>
            <span class="font-mono">{@virtual_ip.ip}</span>
          </span>
        </:subtitle>
        <:actions>
          <Form.button
            :if={Enum.any?(@discovery.providers, &(&1.mode == :write))}
            phx-click="push"
            title={gettext("Write its DNS names to the providers")}
          >
            <.icon name="hero-arrow-up-tray-mini" class="size-4" /> {gettext("Push")}
          </Form.button>
          <Form.button navigate={~p"/virtual-ips/#{@virtual_ip.id}/edit"}>
            <.icon name="hero-pencil-square-mini" class="size-4" /> {gettext("Edit")}
          </Form.button>
          <Form.button
            variant={:danger}
            phx-click="delete"
            data-confirm={gettext("Delete %{name}?", name: @virtual_ip.name)}
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
          <.card title={gettext("DNS names")} padded={false}>
            <.empty_state
              :if={@dns_records == []}
              icon="hero-globe-alt"
              title={gettext("No DNS name")}
            >
              {gettext("Add names in the form, or claim them from Discovery.")}
            </.empty_state>
            <ul
              :if={@dns_records != []}
              id="virtual-ip-dns-names"
              class="divide-y divide-border text-sm"
            >
              <li
                :for={record <- @dns_records}
                class="flex items-center justify-between gap-3 px-5 py-2.5"
              >
                <span class="inline-flex items-center gap-2">
                  <.badge tone={:accent}>DNS</.badge>
                  <span class="font-mono">{record.name}</span>
                </span>
                <span class="font-mono text-muted">{record.address}</span>
              </li>
            </ul>
          </.card>

          <.card title={gettext("Open ports")} padded={false}>
            <:actions>
              <Form.button
                id="refresh-ports"
                size={:small}
                variant={:ghost}
                phx-click="refresh-ports"
                title={gettext("Check the ports again")}
              >
                <.icon name="hero-arrow-path-mini" class="size-4" /> {gettext("Refresh")}
              </Form.button>
            </:actions>
            <.open_ports address_scans={@address_scans} addresses={[@virtual_ip.ip]} />
          </.card>
        </div>

        <.card title={gettext("Details")} class="self-start">
          <.properties>
            <:item label={gettext("Address")}>
              <span class="font-mono">{@virtual_ip.ip}</span>
            </:item>
            <:item label={gettext("Network")}>
              {(@network && @network.name) || "—"}
            </:item>
            <:item label={gettext("Owner")}>
              <.device_link :if={@owner} device={@owner} />
              <span :if={!@owner} class="text-muted">—</span>
            </:item>
            <:item label={gettext("Identifier")}>
              <span class="font-mono text-xs">{@virtual_ip.id}</span>
            </:item>
          </.properties>
          <p :if={@virtual_ip.notes} class="mt-4 text-sm whitespace-pre-line text-muted">
            {@virtual_ip.notes}
          </p>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns), do: ~H""
end
