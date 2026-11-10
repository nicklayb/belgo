defmodule BelgoWeb.Networks.Live.Show do
  @moduledoc """
  A network, read only (edited from its form): details, then each logical range as a
  table of all its addresses, free ones included (`Belgo.Inventory.NetworkUsage`); a
  device whose kind is none of the range's gets a warning triangle. Addresses held
  outside every range are listed last.
  """

  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Inventory
  alias Belgo.Inventory.NetworkUsage
  alias Belgo.Inventory.NetworkUsage.Holder
  alias Belgo.Inventory.Snapshot
  alias Belgo.Network.IpAddress
  alias BelgoWeb.Format
  alias BelgoWeb.Live.Mutation

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:network_id, id)
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    snapshot = socket.assigns.snapshot

    case Snapshot.fetch(snapshot, :networks, socket.assigns.network_id) do
      {:ok, network} ->
        holders_by_address = NetworkUsage.holders_by_address(snapshot, network)

        ranges =
          network.ranges
          |> Enum.sort_by(&IpAddress.sort_key(&1.start))
          |> Enum.map(&{&1, NetworkUsage.range_rows(&1, holders_by_address)})

        socket
        |> assign(:page_title, network.name)
        |> assign(:network, network)
        |> assign(:ranges, ranges)
        |> assign(:outside_rows, NetworkUsage.outside_rows(network, holders_by_address))
        |> assign(:assigned_count, map_size(Map.delete(holders_by_address, network.gateway)))

      {:error, :not_found} ->
        socket
        |> put_flash(:error, gettext("This network no longer exists."))
        |> push_navigate(to: ~p"/networks")
    end
  end

  @impl Phoenix.LiveView
  def handle_event("delete", _params, socket) do
    case Inventory.delete(:networks, socket.assigns.network.id, Mutation.options(socket)) do
      {:ok, network} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{name} deleted.", name: network.name))
         |> push_navigate(to: ~p"/networks")}

      error ->
        {:noreply, put_flash(socket, :error, Mutation.describe_error(error))}
    end
  end

  @impl Phoenix.LiveView
  def render(%{network: _network} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={@network.name} back={~p"/networks"}>
        <:subtitle>
          <span class="inline-flex flex-wrap items-center gap-2">
            <span class="font-mono">{@network.cidr}</span>
            <.badge :if={@network.vlan}>{gettext("VLAN %{vlan}", vlan: @network.vlan)}</.badge>
            <span :if={@network.domain} class="font-mono">{@network.domain}</span>
          </span>
        </:subtitle>
        <:actions>
          <Form.button navigate={~p"/networks/#{@network.id}/edit"}>
            <.icon name="hero-pencil-square-mini" class="size-4" /> {gettext("Edit")}
          </Form.button>
          <Form.button
            variant={:danger}
            phx-click="delete"
            data-confirm={gettext("Delete %{name}?", name: @network.name)}
          >
            <.icon name="hero-trash-mini" class="size-4" /> {gettext("Delete")}
          </Form.button>
        </:actions>
      </.page_header>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <div class="min-w-0 space-y-6">
          <.card :if={@ranges == []}>
            <.empty_state icon="hero-queue-list" title={gettext("No logical range")}>
              {gettext("Name ranges of addresses (servers, IoT…) in the network's form.")}
            </.empty_state>
          </.card>

          <.card
            :for={{{range, result}, index} <- Enum.with_index(@ranges)}
            id={"range-#{index}"}
            title={range.name}
            padded={false}
          >
            <:actions>
              <span class="text-xs text-muted">
                <span class="font-mono">{range.start} – {range.end}</span>
                <span :if={range.kinds != []}>
                  · {Enum.map_join(range.kinds, ", ", &Format.label/1)}
                </span>
                <span :if={match?({:ok, _rows}, result)} class="tabular-nums">
                  · {used_label(result)}
                </span>
              </span>
            </:actions>
            <%= case result do %>
              <% {:ok, rows} -> %>
                <.address_rows id={"range-#{index}-rows"} rows={rows} />
              <% {:too_large, size} -> %>
                <p class="px-5 py-3 text-sm text-muted">
                  {gettext("%{size} addresses: too many to list.", size: size)}
                </p>
            <% end %>
          </.card>

          <.card
            :if={@outside_rows != []}
            title={gettext("Outside the logical ranges")}
            id="outside-ranges"
            padded={false}
          >
            <.address_rows id="outside-ranges-rows" rows={@outside_rows} />
          </.card>
        </div>

        <.card title={gettext("Details")} class="self-start">
          <.properties>
            <:item label={gettext("Range")}>
              <span class="font-mono">{@network.cidr}</span>
            </:item>
            <:item label={gettext("VLAN")}>{@network.vlan || "—"}</:item>
            <:item label={gettext("Gateway")}>
              <span class="font-mono">{@network.gateway || "—"}</span>
            </:item>
            <:item label={gettext("Domain")}>
              <span class="font-mono">{@network.domain || "—"}</span>
            </:item>
            <:item label={gettext("DHCP range")}>
              <%= case Map.fetch(@discovery.correlation.dhcp_ranges, @network.id) do %>
                <% {:ok, range} -> %>
                  <span class="font-mono">{range.start} – {range.end}</span>
                  <.badge :if={range.source != :inventory} class="ml-1">
                    {Format.label(range.source)}
                  </.badge>
                <% :error -> %>
                  —
              <% end %>
            </:item>
            <:item label={gettext("Assigned")}>
              <span class="tabular-nums">{@assigned_count}</span>
            </:item>
            <:item :if={@network.notes} label={gettext("Notes")}>
              <span class="whitespace-pre-line">{@network.notes}</span>
            </:item>
          </.properties>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
    </Layouts.app>
    """
  end

  defp used_label({:ok, rows}),
    do:
      gettext("%{used} used / %{total}", used: NetworkUsage.used_count(rows), total: length(rows))

  attr(:id, :string, required: true)
  attr(:rows, :list, required: true)

  # Addresses and what holds them; free addresses keep an empty row.
  defp address_rows(assigns) do
    ~H"""
    <table id={@id} class="w-full text-sm">
      <thead class="text-left text-xs text-muted">
        <tr class="border-b border-border">
          <th class="w-36 px-5 py-2 font-medium">{gettext("Address")}</th>
          <th class="px-5 py-2 font-medium">{gettext("Device")}</th>
        </tr>
      </thead>
      <tbody class="divide-y divide-border">
        <tr :for={row <- @rows} data-address={row.address} data-free={row.holders == []}>
          <td class={["px-5 py-1.5 font-mono", row.holders == [] && "text-muted"]}>
            {row.address}
          </td>
          <td class="px-5 py-1.5">
            <span :if={row.holders == []} class="text-muted">—</span>
            <span :for={holder <- row.holders} class="mr-3 inline-flex items-center gap-1.5">
              <.holder holder={holder} />
            </span>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr(:holder, Holder, required: true)

  defp holder(%{holder: %Holder{type: :device}} = assigns) do
    ~H"""
    <span
      :if={@holder.kind_mismatch?}
      data-kind-mismatch
      title={gettext("%{kind}, not a kind of this range", kind: Format.label(@holder.device_kind))}
      class="inline-flex"
    >
      <.icon name="hero-exclamation-triangle-mini" class="size-4 text-warning" />
    </span>
    <.link navigate={~p"/devices/#{@holder.id}"} class="font-medium hover:text-accent">
      {@holder.name}
    </.link>
    <span :if={@holder.interface_name} class="text-xs text-muted">{@holder.interface_name}</span>
    <span class="text-xs text-muted">· {Format.label(@holder.device_kind)}</span>
    """
  end

  defp holder(%{holder: %Holder{type: :virtual_ip}} = assigns) do
    ~H"""
    <.link navigate={~p"/virtual-ips/#{@holder.id}"} class="font-medium hover:text-accent">
      {@holder.name}
    </.link>
    <span class="text-xs text-muted">· {gettext("virtual IP")}</span>
    """
  end

  defp holder(%{holder: %Holder{type: :gateway}} = assigns) do
    ~H"""
    <span class="text-muted">{gettext("Gateway")}</span>
    """
  end
end
