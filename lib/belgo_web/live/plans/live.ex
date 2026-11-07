defmodule BelgoWeb.Plans.Live do
  @moduledoc """
  The plan of a home (`plans.yaml`), in 3D by default (`?view=2d` for the drawing),
  with the warnings of the plan. In 2D, one level at a time (`?level=<id>`,
  `exterior` for the outside) with its rooms, measures, doors and devices; in 3D,
  `?level=<id>` shows the home up to that level (to look inside lower ones). Homes
  are selected by `/plan/<id>`; `/plan` shows the first one.

  Clicking a device in 3D (`select-device` from the `Plan3D` hook) shows its network
  path (`Belgo.Topology.Routing.path/3`, live uplinks included): lines between the
  hops placed on the plan (`Belgo.Plans.NetworkPath`) and the whole path in a panel.

  The 3D view filters its devices by kind like the device list (`?kinds=a,b`,
  `Belgo.Inventory.DeviceFilter`); the hops of the shown network path stay visible.
  """

  @behaviour BelgoWeb.Hooks.Discovery
  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.DeviceFilter
  alias Belgo.Inventory.Snapshot
  alias Belgo.Plans.Analysis
  alias Belgo.Plans.NetworkPath
  alias Belgo.Plans.Scene
  alias Belgo.Plans.Zone
  alias Belgo.Topology.Routing
  alias BelgoWeb.Components.PlanDrawing
  alias BelgoWeb.Components.Routing, as: RoutingComponents

  @exterior "exterior"

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Plan"))
     |> assign(:plan_id, Map.get(params, "id"))
     |> assign(:level_id, nil)
     |> assign(:view, :model)
     |> assign(:selected_device_id, nil)
     |> assign(:filter, DeviceFilter.new())
     |> assign_inventory()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:plan_id, Map.get(params, "id"))
     |> assign(:requested_level, Map.get(params, "level"))
     |> assign(:view, if(Map.get(params, "view") == "2d", do: :drawing, else: :model))
     |> assign(:filter, DeviceFilter.new(Map.take(params, ["kinds"])))
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    snapshot = socket.assigns.snapshot
    plan = find_plan(snapshot.plans, socket.assigns.plan_id)

    socket
    |> assign(:plans, snapshot.plans)
    |> assign(:plan, plan)
    |> assign(:device_by_id, Snapshot.index(snapshot, :devices))
    |> assign(:location_by_id, Snapshot.index(snapshot, :locations))
    |> assign_plan(plan, snapshot)
    |> assign_network_path()
  end

  defp patch_filter(socket, filter) do
    %{plan: plan, view: view, level_id: level_id} = socket.assigns
    push_patch(socket, to: level_path(plan, view, level_id, filter), replace: true)
  end

  # Kind boxes counted on the placed devices, and the scene the browser receives:
  # devices of other kinds are flagged `hidden` (still positioned for the path),
  # except the hops of the shown network path.
  defp assign_kind_filter(%{assigns: %{scene: %{devices: devices} = scene}} = socket) do
    %{filter: filter, device_by_id: device_by_id, network_hops: hops} = socket.assigns

    placed_devices =
      for device <- devices, inventory = device_by_id[device.device_id], do: inventory

    kept_ids = MapSet.new(DeviceFilter.apply_filter(placed_devices, filter), & &1.id)
    path_ids = for %{device: %{id: id}} <- hops, into: MapSet.new(), do: id
    filtering? = filter.kinds != []

    shown_devices =
      Enum.map(devices, fn device ->
        hidden? =
          filtering? and not MapSet.member?(kept_ids, device.device_id) and
            not MapSet.member?(path_ids, device.device_id)

        Map.put(device, :hidden, hidden?)
      end)

    assign(socket,
      kind_facets: kind_facets(DeviceFilter.kind_counts(filter, placed_devices), filter.kinds),
      shown_scene: %{scene | devices: shown_devices}
    )
  end

  defp assign_kind_filter(socket), do: assign(socket, kind_facets: [], shown_scene: nil)

  @impl BelgoWeb.Hooks.Discovery
  def assign_discovery(socket), do: assign_network_path(socket)

  @impl Phoenix.LiveView
  def handle_event("toggle-kind", %{"kind" => name}, socket) do
    case Enum.find(Device.kinds(), &(Atom.to_string(&1) == name)) do
      nil ->
        {:noreply, socket}

      kind ->
        {:noreply, patch_filter(socket, DeviceFilter.toggle_kind(socket.assigns.filter, kind))}
    end
  end

  def handle_event("clear-kinds", _params, socket),
    do: {:noreply, patch_filter(socket, %{socket.assigns.filter | kinds: []})}

  def handle_event("select-device", %{"device_id" => device_id}, socket)
      when is_binary(device_id) and device_id != "" do
    {:noreply, select_device(socket, device_id)}
  end

  def handle_event("select-device", _params, socket),
    do: {:noreply, select_device(socket, nil)}

  defp select_device(socket, device_id) do
    socket
    |> assign(:selected_device_id, device_id)
    |> assign_network_path()
  end

  # The path of the selected device, if it is still on the plan.
  defp assign_network_path(socket) do
    socket
    |> assign_path()
    |> assign_kind_filter()
  end

  defp assign_path(%{assigns: %{scene: %{devices: devices}}} = socket) do
    placed_device_ids = MapSet.new(devices, & &1.device_id)
    device_id = socket.assigns.selected_device_id

    if device_id && MapSet.member?(placed_device_ids, device_id) do
      snapshot = socket.assigns.snapshot
      links = Routing.links(snapshot, socket.assigns.discovery.correlation.uplinks)
      hops = Routing.path(snapshot, links, device_id)

      assign(socket,
        network_hops: hops,
        unplaced_device_ids: NetworkPath.unplaced_device_ids(hops, placed_device_ids),
        network_path: %{
          device_id: device_id,
          segments: NetworkPath.segments(hops, placed_device_ids)
        }
      )
    else
      clear_network_path(socket)
    end
  end

  defp assign_path(socket), do: clear_network_path(socket)

  defp clear_network_path(socket),
    do:
      assign(socket,
        selected_device_id: nil,
        network_hops: [],
        unplaced_device_ids: MapSet.new(),
        network_path: nil
      )

  defp assign_plan(socket, nil, _snapshot),
    do: assign(socket, analysis: nil, levels: [], level_id: nil, scene: nil)

  defp assign_plan(socket, plan, snapshot) do
    analysis = Analysis.build(plan, snapshot)
    levels = level_tabs(plan, analysis)
    requested = Map.get(socket.assigns, :requested_level)

    # The 2D drawing always shows a level; the 3D view shows them all by default.
    level_id =
      case {Enum.find(levels, &(&1.key == requested)), socket.assigns[:view]} do
        {nil, :model} -> nil
        {nil, _drawing} -> first_level_key(levels)
        {tab, _view} -> tab.key
      end

    assign(socket,
      analysis: analysis,
      levels: levels,
      level_id: level_id,
      scene: Scene.build(plan, analysis, snapshot)
    )
  end

  defp first_level_key([first | _levels]), do: first.key
  defp first_level_key([]), do: nil

  defp find_plan([], _id), do: nil
  defp find_plan([first | _plans], nil), do: first
  defp find_plan(plans, id), do: Enum.find(plans, &(&1.id == id)) || hd(plans)

  # Levels from the lowest, then the exterior when the plan has exterior zones.
  defp level_tabs(plan, analysis) do
    levels =
      plan.levels
      |> Enum.sort_by(&Map.get(analysis.elevations, &1.id, 0.0))
      |> Enum.map(&%{key: &1.id, name: &1.name, elevation: Map.get(analysis.elevations, &1.id)})

    exterior =
      if Enum.any?(plan.zones, &Zone.exterior?/1),
        do: [%{key: @exterior, name: gettext("Exterior"), elevation: analysis.ground_elevation}],
        else: []

    levels ++ exterior
  end

  defp drawn_level_id(@exterior), do: nil
  defp drawn_level_id(level_id), do: level_id

  defp level_path(plan, view, key, filter) do
    params =
      view
      |> view_params()
      |> Map.merge(DeviceFilter.to_query_params(filter))
      |> then(&if(key, do: Map.put(&1, :level, key), else: &1))

    ~p"/plan/#{plan.id}?#{params}"
  end

  defp view_params(:drawing), do: %{view: "2d"}
  defp view_params(:model), do: %{}

  # In 3D, the selected level and those below it are shown.
  defp visible_up_to(_levels, nil), do: ""

  defp visible_up_to(levels, level_id) do
    case Enum.find(levels, &(&1.key == level_id)) do
      %{elevation: elevation} when is_number(elevation) -> elevation
      _exterior_or_unknown -> ""
    end
  end

  attr(:key, :string, required: true)
  attr(:label, :string, required: true)
  attr(:title, :string, required: true)

  # A show / hide button of the 3D view, handled by the Plan3D hook.
  defp view_toggle(assigns) do
    ~H"""
    <button
      type="button"
      data-toggle={@key}
      aria-pressed="true"
      title={@title}
      class="group inline-flex items-center gap-1.5 rounded-md bg-surface/90 px-2.5 py-1.5 text-sm ring-1 ring-border ring-inset hover:text-accent aria-pressed:text-foreground aria-[pressed=false]:text-muted"
    >
      <.icon name="hero-eye-mini" class="size-4 group-aria-[pressed=false]:hidden" />
      <.icon name="hero-eye-slash-mini" class="hidden size-4 group-aria-[pressed=false]:inline" />
      {@label}
    </button>
    """
  end

  defp elevation_label(nil), do: ""

  defp elevation_label(centimetres),
    do: "#{:erlang.float_to_binary(centimetres / 100, decimals: 2)} m"

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={(@plan && @plan.name) || gettext("Plan")}>
        <:subtitle>{gettext("Where devices physically are, level by level.")}</:subtitle>
        <:actions>
          <nav :if={length(@plans) > 1} class="flex gap-1" aria-label={gettext("Homes")}>
            <.link
              :for={plan <- @plans}
              patch={~p"/plan/#{plan.id}"}
              class={[
                "rounded-md px-3 py-1.5 text-sm font-medium",
                plan.id == @plan.id && "bg-accent-soft text-accent",
                plan.id != @plan.id && "text-muted hover:text-foreground"
              ]}
            >
              {plan.name}
            </.link>
          </nav>
          <Form.button :if={@plan} navigate={~p"/plan/#{@plan.id}/edit"}>
            <.icon name="hero-pencil-square-mini" class="size-4" /> {gettext("Edit")}
          </Form.button>
          <Form.button variant={:primary} navigate={~p"/plan/new"}>
            <.icon name="hero-plus-mini" class="size-4" /> {gettext("New plan")}
          </Form.button>
        </:actions>
      </.page_header>

      <.card :if={!@plan}>
        <.empty_state icon="hero-home-modern" title={gettext("No plan yet")}>
          {gettext("Draw your home level by level, then place your devices in it.")}
        </.empty_state>
      </.card>

      <div :if={@plan} class="space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <nav id="plan-levels" class="flex flex-wrap gap-2" aria-label={gettext("Levels")}>
            <.link
              :if={@view == :model}
              patch={level_path(@plan, @view, nil, @filter)}
              class={[
                "rounded-md px-3 py-1.5 text-sm ring-1 ring-inset",
                is_nil(@level_id) && "bg-accent-soft font-medium text-accent ring-accent",
                @level_id && "text-muted ring-border hover:text-foreground"
              ]}
            >
              {gettext("All")}
            </.link>
            <.link
              :for={level <- @levels}
              :if={@view == :drawing or level.key != "exterior"}
              patch={level_path(@plan, @view, level.key, @filter)}
              class={[
                "rounded-md px-3 py-1.5 text-sm ring-1 ring-inset",
                level.key == @level_id && "bg-accent-soft font-medium text-accent ring-accent",
                level.key != @level_id && "text-muted ring-border hover:text-foreground"
              ]}
            >
              {level.name}
              <span class="ml-1 text-xs tabular-nums opacity-70">
                {elevation_label(level.elevation)}
              </span>
            </.link>
          </nav>
          <nav
            id="plan-views"
            class="inline-flex rounded-md ring-1 ring-border ring-inset"
            aria-label={gettext("View")}
          >
            <.link
              :for={{view, label} <- [model: gettext("3D"), drawing: gettext("2D")]}
              patch={level_path(@plan, view, nil, @filter)}
              class={[
                "px-3 py-1.5 text-sm first:rounded-l-md last:rounded-r-md",
                view == @view && "bg-accent-soft font-medium text-accent",
                view != @view && "text-muted hover:text-foreground"
              ]}
            >
              {label}
            </.link>
          </nav>
        </div>

        <.kind_filter
          :if={@view == :model}
          id="plan-kind-filter"
          facets={@kind_facets}
          toggle="toggle-kind"
          clear="clear-kinds"
        />

        <.card :if={@view == :model} padded={false} class="relative">
          <div
            :if={@network_path}
            id="plan-network-path"
            class="absolute top-3 left-3 z-20 max-w-[min(32rem,calc(100%-22rem))] space-y-1 rounded-md bg-surface/95 px-3 py-2 shadow-sm ring-1 ring-border ring-inset"
          >
            <div class="flex items-center justify-between gap-3 text-xs text-muted">
              <span>{gettext("Network path")}</span>
              <button
                type="button"
                phx-click="select-device"
                title={gettext("Hide the path")}
                class="hover:text-foreground"
              >
                <.icon name="hero-x-mark-micro" class="size-4" />
              </button>
            </div>
            <RoutingComponents.network_path hops={@network_hops} dimmed_ids={@unplaced_device_ids} />
            <p :if={length(@network_hops) < 2} class="text-xs text-muted">
              {gettext("No known uplink for this device.")}
            </p>
            <p :if={length(@network_hops) > 1} class="text-xs text-muted">
              {gettext("Solid: wired · dashed: Wi-Fi · grey dashed: through devices not on the plan")}
              <span :if={MapSet.size(@unplaced_device_ids) > 0}>
                {gettext("(greyed out above).")}
              </span>
            </p>
          </div>
          <div
            id="plan-3d"
            phx-hook="Plan3D"
            phx-update="ignore"
            data-plan-id={@plan.id}
            data-scene={Jason.encode!(@shown_scene)}
            data-visible-up-to={visible_up_to(@levels, @level_id)}
            data-network-path={@network_path && Jason.encode!(@network_path)}
            class="relative h-[70vh] w-full overflow-hidden rounded-xl"
          >
            <div data-viewport class="absolute inset-0"></div>
            <div class="absolute top-3 right-3 z-10 flex max-w-[60%] flex-wrap justify-end gap-2">
              <.view_toggle
                :for={
                  {key, label, title} <- [
                    {"labels", gettext("Labels"), gettext("Show or hide the device labels")},
                    {"names", gettext("Names"), gettext("Show or hide the room names on the floors")},
                    {"facade", gettext("Exterior walls"), gettext("Show or hide the exterior walls")}
                  ]
                }
                key={key}
                label={label}
                title={title}
              />
            </div>
          </div>
        </.card>

        <.card :if={@view == :drawing} padded={false}>
          <div class="p-4">
            <PlanDrawing.level_drawing
              :if={@level_id}
              plan={@plan}
              analysis={@analysis}
              level_id={drawn_level_id(@level_id)}
              device_by_id={@device_by_id}
              location_by_id={@location_by_id}
            />
          </div>
        </.card>

        <.card
          :if={@analysis.warnings != []}
          title={gettext("Warnings")}
          class="border-warning/40"
          padded={false}
        >
          <ul id="plan-warnings" class="divide-y divide-border text-sm">
            <li
              :for={warning <- @analysis.warnings}
              class="flex items-start gap-2 px-5 py-2.5"
              data-warning={warning.kind}
            >
              <.icon
                name="hero-exclamation-triangle-mini"
                class="mt-0.5 size-4 shrink-0 text-warning"
              />
              <span>{warning.message}</span>
            </li>
          </ul>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
