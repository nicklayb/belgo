defmodule BelgoWeb.Sync.Live do
  @moduledoc """
  Preview of what the inventory dictates to AdGuard Home, OPNsense and the Omada
  controller.
  """

  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Sync.DesiredState

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Sync"))
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    assign(socket, :desired_state, DesiredState.build(socket.assigns.snapshot))
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
      <.page_header title={gettext("Sync")}>
        <:subtitle>
          {gettext("What AdGuard Home, OPNsense and Omada must contain according to the inventory.")}
        </:subtitle>
        <:actions>
          <.badge tone={:warning}>{gettext("Preview")}</.badge>
        </:actions>
      </.page_header>

      <div class="space-y-6">
        <.card title={gettext("DNS records")} padded={false}>
          <:actions>
            <.badge>AdGuard Home</.badge>

            <.badge>OPNsense Unbound</.badge>
          </:actions>
          <.table id="dns-records" rows={@desired_state.dns_records}>
            <:col :let={record} label={gettext("Name")}>
              <span class="font-mono">{record.name}</span>
            </:col>
            <:col :let={record} label={gettext("Address")}>
              <span class="font-mono">{record.address}</span>
            </:col>
            <:col :let={record} label={gettext("Owner")} class="hidden sm:table-cell">
              <.link
                :if={record.virtual_ip_id}
                navigate={~p"/virtual-ips/#{record.virtual_ip_id}"}
                class="hover:text-accent"
              >
                {record.virtual_ip_id}
              </.link>
              <.link
                :if={!record.virtual_ip_id}
                navigate={~p"/devices/#{record.device_id}"}
                class="hover:text-accent"
              >
                {record.device_id}
              </.link>
            </:col>
          </.table>
        </.card>

        <.card title={gettext("DHCP reservations")} padded={false}>
          <:actions>
            <.badge>OPNsense</.badge>

            <.badge>Omada</.badge>
          </:actions>
          <.table id="dhcp-reservations" rows={@desired_state.dhcp_reservations}>
            <:col :let={reservation} label={gettext("MAC address")}>
              <span class="font-mono">{reservation.mac}</span>
            </:col>
            <:col :let={reservation} label={gettext("Address")}>
              <span class="font-mono">{reservation.address}</span>
            </:col>
            <:col :let={reservation} label={gettext("Hostname")} class="hidden sm:table-cell">
              <span class="font-mono">{reservation.hostname}</span>
            </:col>
          </.table>
        </.card>

        <.card title={gettext("Client names")} padded={false}>
          <:actions>
            <.badge>Omada</.badge>
          </:actions>
          <.table id="client-names" rows={@desired_state.client_names}>
            <:col :let={client} label={gettext("MAC address")}>
              <span class="font-mono">{client.mac}</span>
            </:col>
            <:col :let={client} label={gettext("Name")}>{client.name}</:col>
          </.table>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
