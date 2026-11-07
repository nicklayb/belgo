defmodule BelgoWeb.Devices.Live.Index do
  @moduledoc "Searchable list of devices."

  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.DeviceFilter
  alias Belgo.Inventory.DeviceSorting
  alias Belgo.Topology.Physical
  alias BelgoWeb.Live.Reachability

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Devices"))
      |> assign(:filter, DeviceFilter.new())
      |> assign(:selected_ids, MapSet.new())
      |> Reachability.subscribe()

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:filter, DeviceFilter.new(params))
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    snapshot = socket.assigns.snapshot

    filter = socket.assigns.filter

    rows =
      snapshot.devices
      |> DeviceFilter.apply_filter(filter)
      |> Enum.map(&{&1, placement_label(snapshot, &1)})
      |> DeviceSorting.sort(filter.sort, filter.direction)

    existing_ids = MapSet.new(snapshot.devices, & &1.id)
    kind_counts = DeviceFilter.kind_counts(socket.assigns.filter, snapshot.devices)

    socket
    |> assign(:devices, rows)
    |> update(:selected_ids, &MapSet.intersection(&1, existing_ids))
    |> assign(:kind_facets, kind_facets(kind_counts, socket.assigns.filter.kinds))
    |> Reachability.check(Enum.flat_map(snapshot.devices, &Device.ip_addresses/1))
  end

  @impl Phoenix.LiveView
  def handle_info({:reachability_changed, address_statuses}, socket),
    do: {:noreply, Reachability.changed(socket, address_statuses)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    filter = DeviceFilter.update(socket.assigns.filter, params)

    {:noreply, push_patch(socket, to: devices_path(filter), replace: true)}
  end

  def handle_event("sort", %{"field" => name}, socket) do
    case DeviceSorting.parse_field(name) do
      nil ->
        {:noreply, socket}

      field ->
        filter = DeviceFilter.sort_by(socket.assigns.filter, field)
        {:noreply, push_patch(socket, to: devices_path(filter), replace: true)}
    end
  end

  def handle_event("toggle-kind", %{"kind" => name}, socket) do
    case Enum.find(Device.kinds(), &(Atom.to_string(&1) == name)) do
      nil ->
        {:noreply, socket}

      kind ->
        filter = DeviceFilter.toggle_kind(socket.assigns.filter, kind)
        {:noreply, push_patch(socket, to: devices_path(filter), replace: true)}
    end
  end

  def handle_event("clear-kinds", _params, socket) do
    filter = %{socket.assigns.filter | kinds: []}
    {:noreply, push_patch(socket, to: devices_path(filter), replace: true)}
  end

  def handle_event("toggle-select", %{"id" => id}, socket) do
    {:noreply,
     update(socket, :selected_ids, fn selected_ids ->
       if MapSet.member?(selected_ids, id),
         do: MapSet.delete(selected_ids, id),
         else: MapSet.put(selected_ids, id)
     end)}
  end

  def handle_event("toggle-select-shown", _params, socket) do
    shown_ids = MapSet.new(socket.assigns.devices, fn {device, _placement} -> device.id end)

    selected_ids =
      if MapSet.subset?(shown_ids, socket.assigns.selected_ids),
        do: MapSet.difference(socket.assigns.selected_ids, shown_ids),
        else: MapSet.union(socket.assigns.selected_ids, shown_ids)

    {:noreply, assign(socket, :selected_ids, selected_ids)}
  end

  def handle_event("clear-selection", _params, socket),
    do: {:noreply, assign(socket, :selected_ids, MapSet.new())}

  defp devices_path(filter), do: ~p"/devices?#{DeviceFilter.to_query_params(filter)}"

  defp all_shown_selected?(devices, selected_ids) do
    devices != [] and Enum.all?(devices, fn {device, _placement} -> device.id in selected_ids end)
  end

  defp bulk_edit_path(filter, selected_ids) do
    params =
      filter
      |> DeviceFilter.to_query_params()
      |> Map.put("ids", Enum.join(Enum.sort(selected_ids), ","))

    ~p"/devices/bulk-edit?#{params}"
  end

  defp placement_label(snapshot, device) do
    %{locations: locations, hosts: hosts} = Physical.device_path(snapshot, device)

    case {Device.placement(device), hosts, locations} do
      {:portable, _hosts, _locations} -> gettext("Portable")
      {:unplaced, _hosts, _locations} -> gettext("Unplaced")
      {_placement, hosts, locations} -> Enum.map_join(locations ++ hosts, " › ", & &1.name)
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
      <.page_header title={gettext("Devices")}>
        <:subtitle>{gettext("Every machine and peripheral of the network.")}</:subtitle>
        <:actions>
          <Form.button variant={:primary} navigate={~p"/devices/new"}>
            <.icon name="hero-plus-mini" class="size-4" /> {gettext("New device")}
          </Form.button>
        </:actions>
      </.page_header>

      <.card padded={false}>
        <.form
          :let={filter_form}
          for={DeviceFilter.to_query_params(@filter)}
          id="device-filter"
          phx-change="filter"
          phx-submit="filter"
          class="flex flex-col gap-3 border-b border-border p-4 sm:flex-row"
        >
          <div class="relative flex-1">
            <.icon
              name="hero-magnifying-glass-mini"
              class="pointer-events-none absolute top-2.5 left-3 size-4 text-muted"
            />
            <input
              type="search"
              name={filter_form[:query].name}
              value={filter_form[:query].value}
              placeholder={gettext("Search by name, hostname, address, tag…")}
              phx-debounce="150"
              class="block w-full rounded-md border-0 bg-surface py-2 pr-3 pl-9 text-sm ring-1 ring-border ring-inset placeholder:text-muted focus:ring-2 focus:ring-accent focus:outline-none"
            />
          </div>
        </.form>

        <.kind_filter
          id="kind-filter"
          facets={@kind_facets}
          toggle="toggle-kind"
          clear="clear-kinds"
          class="border-b border-border px-4 py-3"
        />

        <div
          :if={@devices != []}
          id="device-selection"
          class="flex min-h-12 flex-wrap items-center gap-3 border-b border-border px-5 py-2 text-sm"
        >
          <label class="inline-flex cursor-pointer items-center gap-2 text-muted">
            <input
              type="checkbox"
              phx-click="toggle-select-shown"
              checked={all_shown_selected?(@devices, @selected_ids)}
              class="size-4 rounded border-border accent-accent"
            />
            {gettext("Select all shown")}
          </label>
          <div :if={MapSet.size(@selected_ids) > 0} class="ml-auto flex items-center gap-2">
            <span class="text-muted">
              {ngettext("1 selected", "%{count} selected", MapSet.size(@selected_ids))}
            </span>
            <Form.button size={:small} variant={:ghost} phx-click="clear-selection">
              {gettext("Clear")}
            </Form.button>
            <Form.button
              size={:small}
              variant={:primary}
              navigate={bulk_edit_path(@filter, @selected_ids)}
            >
              <.icon name="hero-pencil-square-micro" class="size-4" /> {gettext("Edit")}
            </Form.button>
          </div>
        </div>

        <.empty_state :if={@devices == []} icon="hero-server" title={gettext("No device")}>
          {gettext("Nothing matches, or the inventory is empty.")}
        </.empty_state>

        <.table
          :if={@devices != []}
          id="devices"
          rows={@devices}
          row_id={fn {device, _placement} -> "device-#{device.id}" end}
          row_click={fn {device, _placement} -> JS.navigate(~p"/devices/#{device.id}") end}
          sort_event="sort"
          sort={{@filter.sort, @filter.direction}}
        >
          <:col :let={{device, _placement}} label="" class="w-0 pr-0" skip_row_click>
            <input
              type="checkbox"
              phx-click="toggle-select"
              phx-value-id={device.id}
              checked={device.id in @selected_ids}
              aria-label={gettext("Select %{name}", name: device.name)}
              class="size-4 cursor-pointer rounded border-border accent-accent"
            />
          </:col>
          <:col :let={{device, _placement}} label={gettext("Name")} sort_field={:name}>
            <div class="flex min-w-0 items-center gap-2">
              <.device_link device={device} />
              <.poe_indicator device={device} />
              <.reachability_indicator status={
                Reachability.status(@address_statuses, Device.ip_addresses(device))
              } />
            </div>
            <p class="mt-0.5 font-mono text-xs text-muted">{Device.hostname(device)}</p>
          </:col>
          <:col
            :let={{_device, placement}}
            label={gettext("Placement")}
            class="hidden md:table-cell"
            sort_field={:placement}
          >
            <span class="text-muted">{placement}</span>
          </:col>
          <:col
            :let={{device, _placement}}
            label={gettext("Addresses")}
            class="hidden sm:table-cell"
            sort_field={:address}
          >
            <p :for={address <- Device.ip_addresses(device)} class="font-mono text-xs">{address}</p>
          </:col>
          <:col :let={{device, _placement}} label={gettext("Tags")} class="hidden lg:table-cell">
            <div class="flex flex-wrap gap-1">
              <.platform_badges platforms={device.platforms} />
              <.badge :for={tag <- device.tags}>{tag}</.badge>
            </div>
          </:col>
        </.table>
      </.card>
    </Layouts.app>
    """
  end
end
