defmodule BelgoWeb.Networks.Live.Index do
  @moduledoc "List of networks with their usage; a row opens the network's page."

  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Network.Cidr
  alias BelgoWeb.Format

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Networks"))
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    snapshot = socket.assigns.snapshot

    # Interface addresses and virtual IPs (in their declared network, else by range).
    address_count_by_network =
      snapshot.devices
      |> Enum.flat_map(& &1.interfaces)
      |> Kernel.++(snapshot.virtual_ips)
      |> Enum.filter(& &1.ip)
      |> Enum.frequencies_by(&(&1.network_id || containing_network_id(snapshot.networks, &1.ip)))

    networks =
      Enum.map(snapshot.networks, fn network ->
        {network, Map.get(address_count_by_network, network.id, 0), capacity(network)}
      end)

    assign(socket, :networks, networks)
  end

  defp containing_network_id(networks, address),
    do: Enum.find_value(networks, &(Belgo.Inventory.Network.contains?(&1, address) && &1.id))

  defp capacity(network) do
    case Cidr.parse(network.cidr) do
      {:ok, cidr} -> Cidr.size(cidr)
      :error -> nil
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
      <.page_header title={gettext("Networks")}>
        <:subtitle>{gettext("Subnets and VLANs addresses are assigned from.")}</:subtitle>
        <:actions>
          <Form.button variant={:primary} navigate={~p"/networks/new"}>
            <.icon name="hero-plus-mini" class="size-4" /> {gettext("New network")}
          </Form.button>
        </:actions>
      </.page_header>

      <.card padded={false}>
        <.empty_state :if={@networks == []} icon="hero-globe-alt" title={gettext("No network yet")} />
        <.table
          :if={@networks != []}
          id="networks"
          rows={@networks}
          row_id={fn {network, _count, _capacity} -> "network-#{network.id}" end}
          row_click={fn {network, _count, _capacity} -> JS.navigate(~p"/networks/#{network.id}") end}
        >
          <:col :let={{network, _count, _capacity}} label={gettext("Name")}>
            <.link navigate={~p"/networks/#{network.id}"} class="font-medium hover:text-accent">
              {network.name}
            </.link>
            <p :if={network.domain} class="font-mono text-xs text-muted">{network.domain}</p>
          </:col>
          <:col :let={{network, _count, _capacity}} label={gettext("Range")}>
            <span class="font-mono">{network.cidr}</span>
            <p
              :for={
                range <- Enum.sort_by(network.ranges, &Belgo.Network.IpAddress.sort_key(&1.start))
              }
              class="text-xs text-muted"
            >
              {range.name}
              <span class="font-mono">{range.start} – {range.end}</span>
              <span :if={range.kind}>· {Format.label(range.kind)}</span>
            </p>
          </:col>
          <:col
            :let={{network, _count, _capacity}}
            label={gettext("VLAN")}
            class="hidden sm:table-cell"
          >
            {network.vlan || "—"}
          </:col>
          <:col
            :let={{network, _count, _capacity}}
            label={gettext("Gateway")}
            class="hidden md:table-cell"
          >
            <span class="font-mono">{network.gateway || "—"}</span>
          </:col>
          <:col
            :let={{network, _count, _capacity}}
            label={gettext("DHCP range")}
            class="hidden lg:table-cell"
          >
            <%= case Map.fetch(@discovery.correlation.dhcp_ranges, network.id) do %>
              <% {:ok, range} -> %>
                <span class="font-mono text-xs">{range.start} – {range.end}</span>
                <.badge :if={range.source != :inventory} class="ml-1">
                  {Format.label(range.source)}
                </.badge>
              <% :error -> %>
                <span class="text-muted">—</span>
            <% end %>
          </:col>
          <:col :let={{_network, count, capacity}} label={gettext("Assigned")}>
            <span class="tabular-nums">{count}</span>
            <span :if={capacity} class="text-muted">{"/ #{capacity}"}</span>
          </:col>
        </.table>
      </.card>
    </Layouts.app>
    """
  end
end
