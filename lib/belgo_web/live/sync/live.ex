defmodule BelgoWeb.Sync.Live do
  @moduledoc """
  The providers (status of their last pull and push, a *Refresh* for a failed one,
  *Push all* sending the whole inventory to the providers in write mode, one run at a
  time) and a preview of what the inventory dictates to AdGuard Home, OPNsense and
  the Omada controller.
  """

  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Discovery
  alias Belgo.Discovery.State.ProviderStatus
  alias Belgo.Sync.DesiredState
  alias BelgoWeb.Components.Providers

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
  def handle_event("refresh-provider", %{"provider" => name}, socket) do
    case Enum.find(socket.assigns.discovery.providers, &(Atom.to_string(&1.key) == name)) do
      %ProviderStatus{key: key} -> Discovery.refresh_provider(key)
      nil -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("push-all", _params, socket) do
    case Discovery.push_all() do
      :ok ->
        {:noreply, put_flash(socket, :info, gettext("Push of every device started."))}

      {:error, :already_running} ->
        {:noreply,
         put_flash(socket, :error, gettext("A push of every device is already running."))}

      {:error, :no_writable_provider} ->
        {:noreply, put_flash(socket, :error, gettext("No provider is in write mode."))}

      {:error, :invalid_settings} ->
        {:noreply, put_flash(socket, :error, gettext("providers.yaml is invalid"))}
    end
  end

  defp writable?(providers), do: Enum.any?(providers, &(&1.mode == :write))

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
        <section id="providers" class="space-y-4">
          <div class="flex flex-wrap items-end justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold">{gettext("Providers")}</h2>
              <p class="text-sm text-muted">
                {gettext("Last pull and last push of each provider configured in providers.yaml.")}
              </p>
            </div>
            <Form.button
              :if={@discovery.providers != []}
              id="push-all"
              variant={:primary}
              phx-click="push-all"
              disabled={@discovery.pushing_all? or not writable?(@discovery.providers)}
              title={
                if writable?(@discovery.providers),
                  do: gettext("Push every device and virtual IP to the providers in write mode"),
                  else: gettext("No provider is in write mode")
              }
            >
              <.icon name="hero-arrow-up-tray-mini" class="size-4" />
              {if @discovery.pushing_all?, do: gettext("Pushing…"), else: gettext("Push all")}
            </Form.button>
          </div>

          <Providers.settings_errors errors={@discovery.settings_errors} />

          <.card :if={@discovery.providers == []}>
            <.empty_state icon="hero-sparkles" title={gettext("No provider configured")}>
              {gettext("Enable providers in providers.yaml, next to the inventory files.")}
            </.empty_state>
          </.card>

          <div
            :if={@discovery.providers != []}
            class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3"
          >
            <Providers.provider_status :for={provider <- @discovery.providers} provider={provider} />
          </div>
        </section>

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
