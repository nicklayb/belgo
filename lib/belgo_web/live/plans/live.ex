defmodule BelgoWeb.Plans.Live do
  @moduledoc """
  The plan of a home (`plans.yaml`), in 3D by default (`?view=2d` for the drawing),
  with the warnings of the plan. In 2D, one level at a time (`?level=<id>`,
  `exterior` for the outside) with its rooms, measures, doors and devices; in 3D,
  `?level=<id>` shows the home up to that level (to look inside lower ones). Homes
  are selected by `/plan/<id>`; `/plan` shows the first one.
  """

  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Inventory.Snapshot
  alias Belgo.Plans.Analysis
  alias Belgo.Plans.Scene
  alias Belgo.Plans.Zone
  alias BelgoWeb.Components.PlanDrawing

  @exterior "exterior"

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Plan"))
     |> assign(:plan_id, Map.get(params, "id"))
     |> assign(:level_id, nil)
     |> assign(:view, :model)
     |> assign_inventory()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:plan_id, Map.get(params, "id"))
     |> assign(:requested_level, Map.get(params, "level"))
     |> assign(:view, if(Map.get(params, "view") == "2d", do: :drawing, else: :model))
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
  end

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

  defp level_path(plan, view, nil), do: ~p"/plan/#{plan.id}?#{view_params(view)}"

  defp level_path(plan, view, key),
    do: ~p"/plan/#{plan.id}?#{Map.put(view_params(view), :level, key)}"

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
              patch={level_path(@plan, @view, nil)}
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
              patch={level_path(@plan, @view, level.key)}
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
              patch={level_path(@plan, view, nil)}
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

        <.card :if={@view == :model} padded={false}>
          <div
            id="plan-3d"
            phx-hook="Plan3D"
            phx-update="ignore"
            data-scene={Jason.encode!(@scene)}
            data-visible-up-to={visible_up_to(@levels, @level_id)}
            class="relative h-[70vh] w-full overflow-hidden rounded-xl"
          >
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
