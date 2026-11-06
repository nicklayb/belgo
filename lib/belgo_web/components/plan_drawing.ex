defmodule BelgoWeb.Components.PlanDrawing do
  @moduledoc """
  Draws one level of a plan (or its exterior, with the home's footprint) as SVG, in
  plan centimetres: rooms with their measures, walls, doors and openings, devices.
  Orphan rooms are drawn dashed. Read only: the editor builds on the same drawing.
  """

  use Phoenix.Component
  use BelgoWeb, :verified_routes
  use Gettext, backend: BelgoWeb.Gettext

  alias Belgo.Plans.Analysis
  alias Belgo.Plans.Editing
  alias Belgo.Plans.Geometry
  alias Belgo.Plans.Opening
  alias Belgo.Plans.Plan
  alias Belgo.Plans.Zone

  @margin_centimetres 100
  # The editor grid extends this many frames around the first one (zoom out, pan).
  @grid_reach_frames 5
  @major_grid_steps 10
  @minimum_size_centimetres 400
  @font_ratio 45
  @wall_ratio 120
  @centimetres_per_metre 100
  @square_centimetres_per_square_metre 10_000

  attr(:plan, Plan, required: true)
  attr(:analysis, Analysis, required: true)
  attr(:level_id, :string, default: nil, doc: "`nil` draws the exterior")
  attr(:device_by_id, :map, required: true)
  attr(:location_by_id, :map, required: true)
  attr(:editable, :boolean, default: false, doc: "grid, selectable zones and openings, handles")
  attr(:selected_zone_id, :string, default: nil)
  attr(:selected_opening, :integer, default: nil, doc: "index in the plan openings")
  attr(:grid, :integer, default: 10, doc: "editor grid step, in centimetres")
  attr(:selected_rectangle, :integer, default: nil, doc: "index in the selected zone")
  attr(:selected_device_id, :string, default: nil, doc: "the selected placed device")

  attr(:hidden, :any,
    default: MapSet.new(),
    doc:
      "editor keys not drawn: `zone:<id>`, `rectangle:<zone id>:<index>`, `placement:<device id>`"
  )

  attr(:ghost_level_ids, :list,
    default: [],
    doc: "other levels drawn faintly under this one (`nil` for the exterior)"
  )

  @doc """
  SVG drawing of a level of the plan. Editable drawings keep a stable frame (every
  level of the home with room around it), show a grid and carry the data attributes
  the `PlanEditor` hook uses (`data-zone`, `data-index`, `data-handle`,
  `data-opening-index`); previews go to `#plan-editor-overlay`, ignored by patches.
  """
  def level_drawing(assigns) do
    zones =
      Enum.filter(
        assigns.plan.zones,
        &(&1.level_id == assigns.level_id and not MapSet.member?(assigns.hidden, "zone:#{&1.id}"))
      )

    zone_ids = MapSet.new(zones, & &1.id)

    view =
      if assigns.editable,
        do: editor_view_box(assigns.plan.zones),
        else: view_box(zones)

    size = max(view.width, view.depth)

    assigns =
      assign(assigns,
        zones: zones,
        view: view,
        font_size: size / @font_ratio,
        wall_width: size / @wall_ratio,
        walls: walls(assigns, zones),
        ghosts: ghost_rectangles(assigns),
        openings:
          for(
            {opening, index} <- Enum.with_index(assigns.plan.openings),
            opening.level_id == assigns.level_id,
            do: {opening, index}
          ),
        placements: Enum.filter(assigns.plan.placements, &MapSet.member?(zone_ids, &1.zone_id)),
        footprint: footprint(assigns.plan, assigns.level_id),
        selected_zone: Enum.find(zones, &(&1.id == assigns.selected_zone_id)),
        grid_reach: @grid_reach_frames,
        major_grid_steps: @major_grid_steps
      )

    ~H"""
    <svg
      id={if(@editable, do: "plan-editor-canvas", else: "plan-level-#{@level_id || "exterior"}")}
      viewBox={"#{@view.x} #{@view.y} #{@view.width} #{@view.depth}"}
      class={[
        "select-none",
        !@editable && "h-auto max-h-[70vh] w-full",
        @editable && "h-full w-full touch-none"
      ]}
      role="img"
      aria-label={gettext("Plan")}
      data-editable={@editable}
      data-level={@level_id || "exterior"}
      data-fit={"#{@view.x} #{@view.y} #{@view.width} #{@view.depth}"}
      phx-mounted={@editable && Phoenix.LiveView.JS.ignore_attributes(["viewBox"])}
    >
      <defs :if={@editable}>
        <%!-- One fine line per grid step (the snapping step), a stronger one every 10. --%>
        <pattern id="plan-grid-step" width={@grid} height={@grid} patternUnits="userSpaceOnUse">
          <path
            d={"M#{@grid} 0H0V#{@grid}"}
            class="fill-none stroke-border"
            stroke-width={@wall_width / 16}
            data-grid-step={@grid}
          />
        </pattern>
        <pattern
          id="plan-grid-pattern"
          width={@grid * @major_grid_steps}
          height={@grid * @major_grid_steps}
          patternUnits="userSpaceOnUse"
        >
          <rect
            width={@grid * @major_grid_steps}
            height={@grid * @major_grid_steps}
            fill="url(#plan-grid-step)"
          />
          <path
            d={"M#{@grid * @major_grid_steps} 0H0V#{@grid * @major_grid_steps}"}
            class="fill-none stroke-muted/40"
            stroke-width={@wall_width / 8}
          />
        </pattern>
      </defs>
      <rect
        :if={@editable}
        x={@view.x - @view.width * @grid_reach}
        y={@view.y - @view.depth * @grid_reach}
        width={@view.width * (2 * @grid_reach + 1)}
        height={@view.depth * (2 * @grid_reach + 1)}
        fill="url(#plan-grid-pattern)"
        data-background
      />
      <g :if={@ghosts != []} data-ghosts class="pointer-events-none">
        <rect
          :for={rectangle <- @ghosts}
          x={rectangle.x}
          y={rectangle.y}
          width={rectangle.width}
          height={rectangle.depth}
          class="fill-muted/10 stroke-muted"
          stroke-width={@wall_width / 4}
          stroke-dasharray={@wall_width}
        />
      </g>
      <g :if={@footprint != []} data-footprint class="pointer-events-none">
        <rect
          :for={rectangle <- @footprint}
          x={rectangle.x}
          y={rectangle.y}
          width={rectangle.width}
          height={rectangle.depth}
          class="fill-muted/20"
        />
      </g>
      <g :for={zone <- @zones} data-zone={zone.id}>
        <rect
          :for={{rectangle, index} <- visible_rectangles(zone, @hidden)}
          x={rectangle.x}
          y={rectangle.y}
          width={rectangle.width}
          height={rectangle.depth}
          class={[
            zone_class(zone, @analysis),
            @editable && "cursor-move",
            zone.id == @selected_zone_id && "fill-accent/20",
            zone.id == @selected_zone_id && index == @selected_rectangle &&
              "fill-accent/35 stroke-accent"
          ]}
          stroke-width={@wall_width / 3}
          data-zone={zone.id}
          data-index={index}
        />
        <g
          :for={
            {side, index} <-
              if(@editable, do: Enum.with_index(Editing.free_sides(@plan, zone.id)), else: [])
          }
          data-extend={zone.id}
          data-side-index={index}
          data-side={side.side}
          data-selected={zone.id == @selected_zone_id}
          class="cursor-pointer"
        >
          <title>{gettext("Add a room on this side")}</title>
          <circle
            cx={side.x + outward(side.side, :x) * @font_size * 0.7}
            cy={side.y + outward(side.side, :y) * @font_size * 0.7}
            r={@font_size * 0.7}
            class="fill-accent stroke-surface"
            stroke-width={@font_size * 0.1}
          />
          <path
            d={
              plus_path(
                side.x + outward(side.side, :x) * @font_size * 0.7,
                side.y + outward(side.side, :y) * @font_size * 0.7,
                @font_size * 0.35
              )
            }
            class="stroke-accent-foreground"
            stroke-width={@font_size * 0.12}
            stroke-linecap="round"
          />
        </g>
        <path
          :if={zone.id in @analysis.orphan_zone_ids}
          d={outline_path(@analysis.measures[zone.id].outline)}
          class="pointer-events-none fill-none stroke-warning"
          stroke-width={@wall_width / 2}
          stroke-dasharray={@wall_width * 2}
        />
      </g>
      <path
        :if={@level_id}
        d={outline_path(@walls)}
        class="pointer-events-none fill-none stroke-foreground"
        stroke-width={@wall_width}
        stroke-linecap="square"
      />
      <g
        :for={{opening, index} <- @openings}
        data-opening={opening.kind}
        data-opening-index={index}
        class={@editable && "cursor-pointer"}
      >
        <path
          d={outline_path([Opening.segment(opening)])}
          class="stroke-surface"
          stroke-width={@wall_width * 1.2}
          data-opening-index={index}
        />
        <path
          d={outline_path([Opening.segment(opening)])}
          class={[
            "fill-none",
            opening.kind == :door && "stroke-accent",
            opening.kind == :opening && "stroke-muted",
            index == @selected_opening && "stroke-warning"
          ]}
          stroke-width={if(index == @selected_opening, do: @wall_width / 1.5, else: @wall_width / 3)}
          stroke-dasharray={opening.kind == :opening && @wall_width}
          data-opening-index={index}
        />
      </g>
      <g :for={zone <- @zones} class={@editable && "pointer-events-none"}>
        <.zone_label
          zone={zone}
          measure={@analysis.measures[zone.id]}
          location={zone.location_id && @location_by_id[zone.location_id]}
          font_size={@font_size}
        />
      </g>
      <g
        :for={placement <- @placements}
        :if={not MapSet.member?(@hidden, "placement:#{placement.device_id}")}
        data-placement={placement.device_id}
        class={@editable && "cursor-grab"}
      >
        <circle
          :if={placement.device_id == @selected_device_id}
          cx={placement.x}
          cy={placement.y}
          r={@font_size * 0.9}
          class="fill-none stroke-accent"
          stroke-width={@font_size * 0.15}
        />
        <.device_marker
          placement={placement}
          device={@device_by_id[placement.device_id]}
          font_size={@font_size}
          linked={!@editable}
        />
      </g>
      <g :if={@selected_zone && @editable} data-handles>
        <rect
          :for={handle <- handles(@selected_zone)}
          x={handle.x - @wall_width}
          y={handle.y - @wall_width}
          width={@wall_width * 2}
          height={@wall_width * 2}
          class="fill-surface stroke-accent"
          stroke-width={@wall_width / 3}
          style={"cursor: #{handle.corner}-resize"}
          data-handle={handle.corner}
          data-zone={@selected_zone.id}
          data-index={handle.index}
        />
      </g>
      <g :if={@editable} id="plan-editor-overlay" phx-update="ignore"></g>
    </svg>
    """
  end

  attr(:zone, Zone, required: true)
  attr(:measure, :any, required: true)
  attr(:location, :any, default: nil)
  attr(:font_size, :float, required: true)

  defp zone_label(assigns) do
    center = label_center(assigns.zone)
    assigns = assign(assigns, x: center.x, y: center.y)

    ~H"""
    <text
      x={@x}
      y={@y}
      text-anchor="middle"
      font-size={@font_size}
      class="fill-foreground font-medium"
    >
      <%= if @location do %>
        <a href={~p"/locations/#{@location.id}"} class="hover:fill-accent">{@zone.name}</a>
      <% else %>
        {@zone.name}
      <% end %>
    </text>
    <text
      x={@x}
      y={@y + @font_size * 1.3}
      text-anchor="middle"
      font-size={@font_size * 0.8}
      class="fill-muted"
      data-measure={@zone.id}
    >
      {measure_label(@measure)}
    </text>
    """
  end

  attr(:placement, :any, required: true)
  attr(:device, :any, default: nil)
  attr(:font_size, :float, required: true)
  attr(:linked, :boolean, default: true, doc: "the label links to the device (not in the editor)")

  defp device_marker(assigns) do
    ~H"""
    <circle
      cx={@placement.x}
      cy={@placement.y}
      r={@font_size * 0.45}
      class={[
        "stroke-surface",
        @device && "fill-accent",
        !@device && "fill-warning"
      ]}
      stroke-width={@font_size * 0.12}
    />
    <text
      x={@placement.x + @font_size * 0.7}
      y={@placement.y + @font_size * 0.35}
      font-size={@font_size * 0.8}
      class="fill-foreground"
    >
      <%= cond do %>
        <% @device && @linked -> %>
          <a href={~p"/devices/#{@device.id}"} class="hover:fill-accent">{@device.name}</a>
        <% @device -> %>
          {@device.name}
        <% true -> %>
          {@placement.device_id}
      <% end %>
    </text>
    """
  end

  @doc "`5.0 × 4.0 m · 20.0 m²`: outer dimensions and surface of a zone."
  @spec measure_label(Analysis.ZoneMeasure.t() | nil) :: String.t()
  def measure_label(nil), do: ""

  def measure_label(%{bounds: bounds, area: area}) do
    "#{metres(bounds.width)} × #{metres(bounds.depth)} m · " <>
      "#{:erlang.float_to_binary(area / @square_centimetres_per_square_metre, decimals: 1)} m²"
  end

  defp metres(centimetres),
    do: :erlang.float_to_binary(centimetres / @centimetres_per_metre, decimals: 1)

  # The exterior shows where the home stands: every room, greyed out.
  defp footprint(plan, nil),
    do:
      for(
        zone <- plan.zones,
        not Zone.exterior?(zone),
        rectangle <- zone.rectangles,
        do: rectangle
      )

  defp footprint(_plan, _level_id), do: []

  defp zone_class(zone, analysis) do
    cond do
      zone.id in analysis.orphan_zone_ids -> "fill-warning/10"
      Zone.exterior?(zone) -> "fill-success/10"
      true -> "fill-accent/5"
    end
  end

  # The label goes in the largest rectangle, so L-shaped rooms keep it inside.
  defp label_center(%Zone{rectangles: rectangles}) do
    largest = Enum.max_by(rectangles, &(&1.width * &1.depth))
    %{x: largest.x + largest.width / 2, y: largest.y + largest.depth / 2}
  end

  defp outline_path(segments) do
    Enum.map_join(segments, " ", fn
      {:horizontal, y, first, last} -> "M#{first} #{y}H#{last}"
      {:vertical, x, first, last} -> "M#{x} #{first}V#{last}"
    end)
  end

  @doc "The rectangles of a zone the editor shows, with their index in the zone."
  @spec visible_rectangles(Zone.t(), MapSet.t()) :: [{map(), non_neg_integer()}]
  def visible_rectangles(zone, hidden) do
    zone.rectangles
    |> Enum.with_index()
    |> Enum.reject(fn {_rectangle, index} ->
      MapSet.member?(hidden, "rectangle:#{zone.id}:#{index}")
    end)
  end

  # In the editor, walls follow what is shown (hidden rooms leave no wall).
  defp walls(%{editable: true, level_id: level_id, hidden: hidden}, zones) when level_id != nil do
    zones
    |> Enum.map(fn zone -> Enum.map(visible_rectangles(zone, hidden), &elem(&1, 0)) end)
    |> Enum.reject(&(&1 == []))
    |> Enum.flat_map(&Geometry.outline/1)
    |> Geometry.merge()
  end

  defp walls(assigns, _zones), do: Map.get(assigns.analysis.walls_by_level, assigns.level_id, [])

  defp ghost_rectangles(%{ghost_level_ids: []}), do: []

  defp ghost_rectangles(assigns) do
    for zone <- assigns.plan.zones,
        zone.level_id in assigns.ghost_level_ids,
        zone.level_id != assigns.level_id,
        not MapSet.member?(assigns.hidden, "zone:#{zone.id}"),
        {rectangle, _index} <- visible_rectangles(zone, assigns.hidden),
        do: rectangle
  end

  # Unit vector pointing out of a side, so the "+" sits outside the room.
  defp outward(:north, :y), do: -1
  defp outward(:south, :y), do: 1
  defp outward(:west, :x), do: -1
  defp outward(:east, :x), do: 1
  defp outward(_side, _axis), do: 0

  defp plus_path(x, y, half),
    do: "M#{x - half} #{y}H#{x + half}M#{x} #{y - half}V#{y + half}"

  # Resize handles at the corners of every rectangle of the selected zone.
  defp handles(zone) do
    for {rectangle, index} <- Enum.with_index(zone.rectangles),
        {corner, x, y} <- corners(rectangle),
        do: %{corner: corner, x: x, y: y, index: index}
  end

  defp corners(rectangle) do
    right = rectangle.x + rectangle.width
    bottom = rectangle.y + rectangle.depth

    [
      {"nw", rectangle.x, rectangle.y},
      {"ne", right, rectangle.y},
      {"sw", rectangle.x, bottom},
      {"se", right, bottom}
    ]
  end

  @editor_margin_centimetres 400
  @editor_minimum_width_centimetres 1600
  @editor_minimum_depth_centimetres 1000

  # The same frame for every level, with room to draw around the home.
  defp editor_view_box(zones) do
    case Geometry.bounds(Enum.flat_map(zones, & &1.rectangles)) do
      nil ->
        %{
          x: 0,
          y: 0,
          width: @editor_minimum_width_centimetres,
          depth: @editor_minimum_depth_centimetres
        }

      bounds ->
        width =
          max(bounds.width + 2 * @editor_margin_centimetres, @editor_minimum_width_centimetres)

        depth =
          max(bounds.depth + 2 * @editor_margin_centimetres, @editor_minimum_depth_centimetres)

        %{
          x: bounds.x + bounds.width / 2 - width / 2,
          y: bounds.y + bounds.depth / 2 - depth / 2,
          width: width,
          depth: depth
        }
    end
  end

  defp view_box([]),
    do: %{x: 0, y: 0, width: @minimum_size_centimetres, depth: @minimum_size_centimetres}

  defp view_box(zones) do
    bounds = Geometry.bounds(Enum.flat_map(zones, & &1.rectangles))

    %{
      x: bounds.x - @margin_centimetres,
      y: bounds.y - @margin_centimetres,
      width: bounds.width + 2 * @margin_centimetres,
      depth: bounds.depth + 2 * @margin_centimetres
    }
  end
end
