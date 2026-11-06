defmodule BelgoWeb.Plans.Editor do
  @moduledoc """
  The plan editor (`/plan/new`, `/plan/:id/edit`): draws the levels in 2D on a
  centimetre grid. The draft lives in memory and is saved by itself once left alone
  for `plan.autosave_delay` of `config.yaml` (an indicator tells where it stands),
  and before leaving. Gestures come from the `PlanEditor` hook; edits are
  `Belgo.Plans.Editing` functions.

  Edits are kept in an in-memory history (Ctrl+Z / Ctrl+Shift+Z, lost on reload).
  The element tree focuses levels, rooms and rectangles; its eyes hide rooms and
  rectangles, and show other levels faintly under the edited one (references).
  """

  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Config
  alias Belgo.Inventory
  alias Belgo.Inventory.Codec
  alias Belgo.Inventory.Snapshot
  alias Belgo.Plans.Analysis
  alias Belgo.Plans.Editing
  alias Belgo.Plans.Ground
  alias Belgo.Plans.Opening
  alias Belgo.Plans.Plan
  alias BelgoWeb.Components.PlanDrawing
  alias BelgoWeb.Live.Mutation

  @exterior "exterior"
  @maximum_percent 100
  @history_size 100
  @default_grid_centimetres 10
  @grids [5, 10, 25, 50, 100]
  @tools ~w(select draw rectangle split door opening place)
  @offsets [
    {"Half a level up", 0.5},
    {"One level up", 1.0},
    {"Half a level down", -0.5},
    {"One level down", -1.0}
  ]

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(
        tool: "select",
        selected: nil,
        grid: @default_grid_centimetres,
        split_axis: :vertical,
        status: :saved,
        saved_at: nil,
        history: [],
        future: [],
        hidden: MapSet.new(),
        references: MapSet.new(),
        selected_rectangle: nil,
        placing_device_id: nil,
        save_timer: nil,
        autosave_delay: Config.current().plan.autosave_delay
      )
      |> assign_inventory()

    case Map.fetch(params, "id") do
      :error ->
        {:ok, assign(socket, page_title: gettext("New plan"), draft: nil, persisted?: false)}

      {:ok, id} ->
        case Snapshot.fetch(socket.assigns.snapshot, :plans, id) do
          {:ok, plan} ->
            {:ok,
             socket
             |> assign(page_title: gettext("Edit %{name}", name: plan.name), persisted?: true)
             |> assign_draft(plan)
             |> assign(:level_key, first_level_key(plan))}

          {:error, :not_found} ->
            {:ok,
             socket
             |> put_flash(:error, gettext("This plan no longer exists."))
             |> push_navigate(to: ~p"/plan")}
        end
    end
  end

  # After creating a home, the URL moves to its edit page; the draft stays.
  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    snapshot = socket.assigns.snapshot

    socket
    |> assign(:location_options, Enum.map(snapshot.locations, &{&1.name, &1.id}))
    |> assign(:device_by_id, Snapshot.index(snapshot, :devices))
    |> assign(:location_by_id, Snapshot.index(snapshot, :locations))
    |> refresh_analysis()
  end

  @impl Phoenix.LiveView
  def handle_info(:autosave, socket), do: {:noreply, save(assign(socket, :save_timer, nil))}
  def handle_info(_message, socket), do: {:noreply, socket}

  # Pending changes are saved before the page goes away.
  @impl Phoenix.LiveView
  def terminate(_reason, %{assigns: %{status: :pending}} = socket) do
    save(socket)
    :ok
  end

  def terminate(_reason, _socket), do: :ok

  @impl Phoenix.LiveView
  def handle_event("create", %{"plan" => %{"name" => name}}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, put_flash(socket, :error, gettext("Give the home a name."))}
    else
      plan = Editing.new_plan(name)

      socket =
        socket
        |> assign(page_title: gettext("Edit %{name}", name: name), level_key: @exterior)
        |> assign_draft(plan)
        |> save()

      case socket.assigns.status do
        :saved -> {:noreply, push_patch(socket, to: ~p"/plan/#{plan.id}/edit")}
        _error -> {:noreply, assign(socket, :draft, nil)}
      end
    end
  end

  def handle_event("tool", %{"tool" => tool}, socket) when tool in @tools,
    do: {:noreply, assign(socket, :tool, tool)}

  def handle_event("grid", %{"grid" => grid}, socket) do
    case Integer.parse(grid) do
      {value, ""} when value in @grids -> {:noreply, assign(socket, :grid, value)}
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("axis", %{"axis" => axis}, socket) when axis in ["vertical", "horizontal"],
    do: {:noreply, assign(socket, :split_axis, String.to_existing_atom(axis))}

  def handle_event("level", %{"key" => key}, socket),
    do: {:noreply, assign(socket, level_key: key, selected: nil)}

  def handle_event("select-zone", %{"zone_id" => zone_id} = params, socket),
    do:
      {:noreply, assign(socket, selected: {:zone, zone_id}, selected_rectangle: params["index"])}

  def handle_event("select-opening", %{"index" => index}, socket),
    do: {:noreply, assign(socket, selected: {:opening, index}, selected_rectangle: nil)}

  def handle_event("select-placement", %{"device_id" => device_id}, socket),
    do: {:noreply, assign(socket, selected: {:placement, device_id}, selected_rectangle: nil)}

  def handle_event("choose-device", %{"device_id" => device_id}, socket),
    do: {:noreply, assign(socket, placing_device_id: blank_to_nil(device_id), tool: "place")}

  def handle_event("place", %{"x" => x, "y" => y}, socket) do
    case socket.assigns.placing_device_id do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Choose the device to place first."))}

      device_id ->
        {:noreply, place(socket, device_id, x, y, "select")}
    end
  end

  def handle_event("extend-room", %{"zone_id" => zone_id, "index" => index}, socket) do
    zone = Enum.find(socket.assigns.draft.zones, &(&1.id == zone_id))
    name = next_zone_name(socket.assigns.draft, zone && zone.level_id)

    case Editing.add_adjacent_zone(socket.assigns.draft, zone_id, index, name) do
      {:ok, plan, new_zone_id} ->
        {:noreply,
         assign(change(socket, {:ok, plan}),
           selected: {:zone, new_zone_id},
           selected_rectangle: 0
         )}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("move-placement", %{"device_id" => device_id, "x" => x, "y" => y}, socket),
    do: {:noreply, place(socket, device_id, x, y, socket.assigns.tool)}

  def handle_event(
        "update-placement",
        %{"placement" => params},
        %{assigns: %{selected: {:placement, device_id}}} = socket
      ) do
    attributes =
      %{}
      |> put_present(
        :anchor,
        Enum.find(Belgo.Plans.Placement.anchors(), &(Atom.to_string(&1) == params["anchor"]))
      )
      |> put_present(:height, parse_integer(params["height"]))

    {:noreply,
     change(socket, Editing.update_placement(socket.assigns.draft, device_id, attributes))}
  end

  def handle_event(
        "remove-placement",
        _params,
        %{assigns: %{selected: {:placement, device_id}}} = socket
      ) do
    {:noreply,
     socket
     |> change(Editing.remove_placement(socket.assigns.draft, device_id))
     |> assign(:selected, nil)}
  end

  # Edits devices.yaml on the owner's click only: the device's location becomes the
  # location of the room it is drawn in.
  def handle_event("set-device-location", %{"device_id" => device_id}, socket) do
    with %{zone_id: zone_id} <-
           Enum.find(socket.assigns.draft.placements, &(&1.device_id == device_id)),
         %{location_id: location_id} when is_binary(location_id) <-
           Enum.find(socket.assigns.draft.zones, &(&1.id == zone_id)),
         {:ok, device} <- Snapshot.fetch(socket.assigns.snapshot, :devices, device_id) do
      params =
        Map.merge(Codec.encode(device), %{"placement" => "location", "location_id" => location_id})

      case Inventory.update(:devices, device_id, params, Mutation.options(socket)) do
        {:ok, device} ->
          {:noreply,
           put_flash(
             socket,
             :info,
             gettext("%{name} moved to its room's location.", name: device.name)
           )}

        error ->
          {:noreply, put_flash(socket, :error, Mutation.describe_error(error))}
      end
    else
      _missing -> {:noreply, put_flash(socket, :error, gettext("This room has no location."))}
    end
  end

  def handle_event("deselect", _params, socket),
    do: {:noreply, assign(socket, selected: nil, selected_rectangle: nil)}

  def handle_event("key", %{"action" => "undo"}, socket), do: {:noreply, undo(socket)}
  def handle_event("key", %{"action" => "redo"}, socket), do: {:noreply, redo(socket)}

  def handle_event("key", %{"action" => "delete"}, socket),
    do: {:noreply, delete_selection(socket)}

  def handle_event("key", %{"action" => "escape"}, socket),
    do: {:noreply, assign(socket, selected: nil, selected_rectangle: nil, tool: "select")}

  # Eyes: rooms and rectangles are hidden; levels (and the exterior) are references.
  def handle_event("toggle-visibility", %{"key" => "zone:" <> _ = key}, socket),
    do: {:noreply, update(socket, :hidden, &toggle(&1, key))}

  def handle_event("toggle-visibility", %{"key" => "rectangle:" <> _ = key}, socket),
    do: {:noreply, update(socket, :hidden, &toggle(&1, key))}

  def handle_event("toggle-visibility", %{"key" => "placement:" <> _ = key}, socket),
    do: {:noreply, update(socket, :hidden, &toggle(&1, key))}

  def handle_event("toggle-visibility", %{"key" => level_key}, socket),
    do: {:noreply, update(socket, :references, &toggle(&1, level_key))}

  def handle_event("focus", %{"level" => level_key} = params, socket) do
    selected =
      cond do
        params["device"] -> {:placement, params["device"]}
        params["zone"] -> {:zone, params["zone"]}
        true -> nil
      end

    rectangle =
      case Integer.parse(params["rectangle"] || "") do
        {index, ""} -> index
        _none -> nil
      end

    {:noreply,
     assign(socket, level_key: level_key, selected: selected, selected_rectangle: rectangle)}
  end

  def handle_event("set-rectangle-values", %{"index" => index, "rectangle" => values}, socket) do
    with {:zone, zone_id} <- socket.assigns.selected,
         {position, ""} <- Integer.parse(index),
         [x, y, width, depth] <- Enum.map(~w(x y width depth), &parse_integer(values[&1])),
         true <- Enum.all?([x, y, width, depth], &is_integer/1) and width > 0 and depth > 0 do
      rectangle = %{x: x, y: y, width: width, depth: depth}

      {:noreply,
       socket
       |> change(Editing.set_rectangle(socket.assigns.draft, zone_id, position, rectangle))
       |> assign(:selected_rectangle, position)}
    else
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("draw", params, socket) do
    rectangle = snapped_rectangle(params, socket.assigns.grid)

    case socket.assigns do
      %{tool: "rectangle", selected: {:zone, zone_id}} ->
        {:noreply,
         change(socket, Editing.add_rectangle(socket.assigns.draft, zone_id, rectangle))}

      %{tool: "draw"} ->
        level_id = drawn_level_id(socket.assigns.level_key)
        name = next_zone_name(socket.assigns.draft, level_id)

        {:ok, plan, zone_id} = Editing.add_zone(socket.assigns.draft, level_id, [rectangle], name)

        {:noreply,
         assign(change(socket, {:ok, plan}), selected: {:zone, zone_id}, tool: "select")}

      _other ->
        {:noreply, put_flash(socket, :error, gettext("Select a room first."))}
    end
  end

  def handle_event("move", %{"zone_id" => zone_id, "whole" => true} = params, socket) do
    {:noreply,
     socket
     |> change(
       Editing.move_zone(socket.assigns.draft, zone_id, params["delta_x"], params["delta_y"])
     )
     |> assign(:selected, {:zone, zone_id})}
  end

  def handle_event("move", %{"zone_id" => zone_id, "index" => index} = params, socket) do
    with %{rectangles: rectangles} <- Enum.find(socket.assigns.draft.zones, &(&1.id == zone_id)),
         %{} = rectangle <- Enum.at(rectangles, index) do
      moved = %{
        rectangle
        | x: rectangle.x + params["delta_x"],
          y: rectangle.y + params["delta_y"]
      }

      {:noreply,
       socket
       |> change(Editing.set_rectangle(socket.assigns.draft, zone_id, index, moved))
       |> assign(:selected, {:zone, zone_id})}
    else
      _missing -> {:noreply, socket}
    end
  end

  def handle_event("set-rectangle", %{"zone_id" => zone_id, "index" => index} = params, socket) do
    rectangle = snapped_rectangle(params, socket.assigns.grid)

    {:noreply,
     change(socket, Editing.set_rectangle(socket.assigns.draft, zone_id, index, rectangle))}
  end

  def handle_event("split", %{"zone_id" => zone_id} = params, socket) do
    axis = socket.assigns.split_axis
    position = if axis == :vertical, do: params["x"], else: params["y"]
    zone = Enum.find(socket.assigns.draft.zones, &(&1.id == zone_id))
    name = next_zone_name(socket.assigns.draft, zone && zone.level_id)

    case Editing.split_zone(
           socket.assigns.draft,
           zone_id,
           axis,
           Editing.snap(position, socket.assigns.grid),
           name
         ) do
      {:ok, plan, new_zone_id} ->
        {:noreply,
         assign(change(socket, {:ok, plan}), selected: {:zone, new_zone_id}, tool: "select")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("add-opening", %{"x" => x, "y" => y}, socket) do
    case drawn_level_id(socket.assigns.level_key) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Exterior zones have no walls."))}

      level_id ->
        kind = String.to_existing_atom(socket.assigns.tool)

        result =
          Editing.add_opening(socket.assigns.draft, socket.assigns.analysis, level_id, x, y, kind)

        case result do
          {:ok, plan} ->
            {:noreply,
             socket
             |> change({:ok, plan})
             |> assign(selected: {:opening, length(plan.openings) - 1}, tool: "select")}

          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

  def handle_event(
        "update-zone",
        %{"zone" => params},
        %{assigns: %{selected: {:zone, zone_id}}} = socket
      ) do
    attributes = %{
      name: blank_to_default(params["name"], zone_id),
      location_id: blank_to_nil(params["location_id"])
    }

    {:noreply, change(socket, Editing.update_zone(socket.assigns.draft, zone_id, attributes))}
  end

  def handle_event("delete-zone", _params, %{assigns: %{selected: {:zone, zone_id}}} = socket) do
    {:noreply,
     socket
     |> change(Editing.delete_zone(socket.assigns.draft, zone_id))
     |> assign(:selected, nil)}
  end

  def handle_event(
        "delete-rectangle",
        %{"index" => index},
        %{assigns: %{selected: {:zone, zone_id}}} = socket
      ) do
    {:noreply,
     change(
       socket,
       Editing.delete_rectangle(socket.assigns.draft, zone_id, String.to_integer(index))
     )}
  end

  def handle_event("anchor", %{"zone_id" => zone_id}, socket),
    do: {:noreply, change(socket, Editing.anchor_zone(socket.assigns.draft, zone_id))}

  def handle_event(
        "update-opening",
        %{"opening" => params},
        %{assigns: %{selected: {:opening, index}}} = socket
      ) do
    attributes =
      %{}
      |> put_present(:kind, parse_kind(params["kind"]))
      |> put_present(:width, parse_positive(params["width"]))

    {:noreply, change(socket, Editing.update_opening(socket.assigns.draft, index, attributes))}
  end

  def handle_event("delete-opening", _params, %{assigns: %{selected: {:opening, index}}} = socket) do
    {:noreply,
     socket
     |> change(Editing.delete_opening(socket.assigns.draft, index))
     |> assign(:selected, nil)}
  end

  def handle_event("add-level", %{"level" => params}, socket) do
    name = blank_to_default(params["name"], gettext("Level"))
    base_id = blank_to_nil(params["base_id"])
    offset = if base_id, do: parse_offset(params["offset"]), else: 0.0
    copy? = params["copy"] == "true"

    {:ok, plan, level_id} = Editing.add_level(socket.assigns.draft, name, base_id, offset, copy?)
    {:noreply, assign(change(socket, {:ok, plan}), level_key: level_id, selected: nil)}
  end

  def handle_event("update-level", %{"level_id" => level_id, "level" => params}, socket) do
    base_id = blank_to_nil(params["base_id"])

    attributes = %{
      name: blank_to_default(params["name"], level_id),
      base_id: base_id,
      offset: if(base_id, do: parse_offset(params["offset"]), else: 0.0)
    }

    {:noreply, change(socket, Editing.update_level(socket.assigns.draft, level_id, attributes))}
  end

  def handle_event("delete-level", %{"level_id" => level_id}, socket) do
    {:noreply,
     socket
     |> change(Editing.delete_level(socket.assigns.draft, level_id))
     |> assign(level_key: first_level_key(socket.assigns.draft, level_id), selected: nil)}
  end

  def handle_event("update-settings", %{"settings" => params}, socket) do
    ground =
      case blank_to_nil(params["ground_level_id"]) do
        nil -> nil
        level_id -> %Ground{level_id: level_id, percent: parse_percent(params["ground_percent"])}
      end

    attributes =
      %{
        name: blank_to_default(params["name"], socket.assigns.draft.name),
        location_id: blank_to_nil(params["location_id"]),
        ground: ground
      }
      |> put_present(:wall_height, parse_positive(params["wall_height"]))
      |> put_present(:level_height, parse_positive(params["level_height"]))

    {:noreply, change(socket, Editing.update_settings(socket.assigns.draft, attributes))}
  end

  def handle_event("save-now", _params, socket), do: {:noreply, save(cancel_timer(socket))}

  def handle_event("done", _params, socket) do
    socket = save(cancel_timer(socket))

    case socket.assigns.status do
      :saved ->
        {:noreply, push_navigate(socket, to: ~p"/plan/#{socket.assigns.draft.id}")}

      _not_saved ->
        {:noreply,
         put_flash(socket, :error, gettext("Fix the plan before leaving: it is not saved."))}
    end
  end

  # Applies an edit: the draft changes (the previous one goes to the history) and a
  # save is scheduled.
  defp change(socket, {:ok, %Plan{} = plan}) do
    socket
    |> assign(
      history: Enum.take([socket.assigns.draft | socket.assigns.history], @history_size),
      future: []
    )
    |> replace_draft(plan)
  end

  defp change(socket, {:ok, %Plan{} = plan, _identifier}), do: change(socket, {:ok, plan})
  defp change(socket, {:error, message}), do: put_flash(socket, :error, message)

  defp undo(%{assigns: %{history: [previous | history]}} = socket) do
    socket
    |> assign(history: history, future: [socket.assigns.draft | socket.assigns.future])
    |> replace_draft(previous)
    |> keep_valid_selection()
  end

  defp undo(socket), do: socket

  defp redo(%{assigns: %{future: [next | future]}} = socket) do
    socket
    |> assign(future: future, history: [socket.assigns.draft | socket.assigns.history])
    |> replace_draft(next)
    |> keep_valid_selection()
  end

  defp redo(socket), do: socket

  defp keep_valid_selection(%{assigns: %{selected: {:zone, zone_id}, draft: draft}} = socket) do
    if Enum.any?(draft.zones, &(&1.id == zone_id)),
      do: socket,
      else: assign(socket, selected: nil, selected_rectangle: nil)
  end

  defp keep_valid_selection(%{assigns: %{selected: {:opening, index}, draft: draft}} = socket) do
    if index < length(draft.openings), do: socket, else: assign(socket, :selected, nil)
  end

  defp keep_valid_selection(
         %{assigns: %{selected: {:placement, device_id}, draft: draft}} = socket
       ) do
    if Enum.any?(draft.placements, &(&1.device_id == device_id)),
      do: socket,
      else: assign(socket, :selected, nil)
  end

  defp keep_valid_selection(socket), do: socket

  defp place(socket, device_id, x, y, next_tool) do
    level_id = drawn_level_id(socket.assigns.level_key)

    case Editing.place_device(socket.assigns.draft, device_id, level_id, x, y) do
      {:ok, plan} ->
        socket
        |> change({:ok, plan})
        |> assign(selected: {:placement, device_id}, tool: next_tool)

      {:error, message} ->
        put_flash(socket, :error, message)
    end
  end

  # Delete key: the selected rectangle of a room with several, else the room, or the
  # selected door / opening or placed device.
  defp delete_selection(%{assigns: %{selected: {:placement, device_id}}} = socket) do
    socket
    |> change(Editing.remove_placement(socket.assigns.draft, device_id))
    |> assign(:selected, nil)
  end

  defp delete_selection(%{assigns: %{selected: {:opening, index}}} = socket) do
    socket
    |> change(Editing.delete_opening(socket.assigns.draft, index))
    |> assign(:selected, nil)
  end

  defp delete_selection(
         %{assigns: %{selected: {:zone, zone_id}, selected_rectangle: index}} = socket
       ) do
    zone = Enum.find(socket.assigns.draft.zones, &(&1.id == zone_id))

    if zone && is_integer(index) && length(zone.rectangles) > 1 do
      socket
      |> change(Editing.delete_rectangle(socket.assigns.draft, zone_id, index))
      |> assign(:selected_rectangle, nil)
    else
      socket
      |> change(Editing.delete_zone(socket.assigns.draft, zone_id))
      |> assign(selected: nil, selected_rectangle: nil)
    end
  end

  defp delete_selection(socket), do: socket

  defp toggle(set, key),
    do: if(MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key))

  defp parse_integer(value) do
    case Integer.parse(value || "") do
      {number, ""} -> number
      _invalid -> nil
    end
  end

  defp replace_draft(socket, plan) do
    socket
    |> assign_draft(plan)
    |> cancel_timer()
    |> assign(
      status: :pending,
      save_timer: Process.send_after(self(), :autosave, socket.assigns.autosave_delay)
    )
  end

  defp cancel_timer(%{assigns: %{save_timer: nil}} = socket), do: socket

  defp cancel_timer(socket) do
    Process.cancel_timer(socket.assigns.save_timer)
    assign(socket, :save_timer, nil)
  end

  defp save(%{assigns: %{draft: nil}} = socket), do: socket

  defp save(socket) do
    draft = socket.assigns.draft
    params = Codec.encode(draft)
    options = Mutation.options(socket)

    result =
      if socket.assigns.persisted?,
        do: Inventory.update(:plans, draft.id, params, options),
        else: Inventory.create(:plans, params, options)

    case result do
      {:ok, _plan} ->
        assign(socket, status: :saved, saved_at: DateTime.utc_now(), persisted?: true)

      {:error, :record, %Ecto.Changeset{} = changeset, _changes} ->
        assign(socket, :status, {:error, changeset_messages(changeset)})

      error ->
        assign(socket, :status, {:error, [Mutation.describe_error(error)]})
    end
  end

  defp assign_draft(socket, plan) do
    socket
    |> assign(:draft, plan)
    |> refresh_analysis()
  end

  defp refresh_analysis(%{assigns: %{draft: %Plan{} = plan, snapshot: snapshot}} = socket),
    do: assign(socket, :analysis, Analysis.build(plan, snapshot))

  defp refresh_analysis(socket), do: assign(socket, :analysis, nil)

  defp changeset_messages(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _options} -> message end)
    |> flatten_messages()
  end

  defp flatten_messages(errors) when is_map(errors),
    do: Enum.flat_map(errors, fn {_field, nested} -> flatten_messages(nested) end)

  defp flatten_messages(errors) when is_list(errors),
    do: Enum.flat_map(errors, &flatten_messages/1)

  defp flatten_messages(message) when is_binary(message), do: [message]

  defp snapped_rectangle(params, grid) do
    x = Editing.snap(params["x"], grid)
    y = Editing.snap(params["y"], grid)

    %{
      x: x,
      y: y,
      width: max(Editing.snap(params["width"], grid), grid),
      depth: max(Editing.snap(params["depth"], grid), grid)
    }
  end

  defp next_zone_name(plan, level_id) do
    count = Enum.count(plan.zones, &(&1.level_id == level_id)) + 1

    if level_id,
      do: gettext("Room %{number}", number: count),
      else: gettext("Exterior %{number}", number: count)
  end

  defp first_level_key(plan, excluded \\ nil) do
    case Enum.reject(plan.levels, &(&1.id == excluded)) do
      [first | _levels] -> first.id
      [] -> @exterior
    end
  end

  defp drawn_level_id(@exterior), do: nil
  defp drawn_level_id(level_id), do: level_id

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: String.trim(value)

  defp blank_to_default(value, default), do: blank_to_nil(value) || default

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp parse_positive(value) do
    case Integer.parse(value || "") do
      {number, ""} when number > 0 -> number
      _invalid -> nil
    end
  end

  defp parse_percent(value) do
    case Integer.parse(value || "") do
      {number, ""} -> min(max(number, 0), @maximum_percent)
      _invalid -> 0
    end
  end

  defp parse_offset(value) do
    case Float.parse(value || "") do
      {number, _rest} -> number
      :error -> 1.0
    end
  end

  defp parse_kind(value), do: Enum.find(Opening.kinds(), &(Atom.to_string(&1) == value))

  defp level_tabs(plan, analysis) do
    levels = Enum.sort_by(plan.levels, &Map.get(analysis.elevations, &1.id, 0.0))
    Enum.map(levels, &{&1.id, &1.name}) ++ [{@exterior, gettext("Exterior")}]
  end

  defp selected_zone(%{selected: {:zone, zone_id}, draft: draft}),
    do: Enum.find(draft.zones, &(&1.id == zone_id))

  defp selected_zone(_assigns), do: nil

  defp selected_placement(%{selected: {:placement, device_id}, draft: draft}),
    do: Enum.find(draft.placements, &(&1.device_id == device_id))

  defp selected_placement(_assigns), do: nil

  defp zone_name(draft, zone_id) do
    case Enum.find(draft.zones, &(&1.id == zone_id)) do
      nil -> zone_id
      zone -> zone.name
    end
  end

  # Devices by name; those already on the plan say where.
  defp device_options(device_by_id, draft) do
    zone_by_device = Map.new(draft.placements, &{&1.device_id, zone_name(draft, &1.zone_id)})

    device_by_id
    |> Map.values()
    |> Enum.sort_by(&String.downcase(&1.name))
    |> Enum.map(fn device ->
      case Map.fetch(zone_by_device, device.id) do
        {:ok, zone} -> {"#{device.name} (#{zone})", device.id}
        :error -> {device.name, device.id}
      end
    end)
  end

  defp selected_opening(%{selected: {:opening, index}, draft: draft}),
    do: Enum.at(draft.openings, index)

  defp selected_opening(_assigns), do: nil

  defp tool_hint("select"),
    do:
      gettext(
        "Click a room to select it, drag to move it (Shift: the whole room), drag a corner to resize, + on a free side adds a room."
      )

  defp tool_hint("draw"),
    do: gettext("Drag on the grid to draw a room (an exterior zone on the Exterior tab).")

  defp tool_hint("rectangle"),
    do: gettext("Drag to add a rectangle to the selected room, touching it (L-shaped rooms).")

  defp tool_hint("split"),
    do: gettext("Click in a room to split it in two along the chosen direction.")

  defp tool_hint("door"), do: gettext("Click on a wall to add a door.")
  defp tool_hint("opening"), do: gettext("Click on a wall to add an opening (no door).")

  defp tool_hint("place"),
    do:
      gettext(
        "Choose a device, then click in a room: near a wall it hangs on it, elsewhere it stands on the floor."
      )

  defp tools do
    [
      {"select", gettext("Select"), "hero-cursor-arrow-rays-mini", "V"},
      {"draw", gettext("Room"), "hero-square-2-stack-mini", "R"},
      {"rectangle", gettext("Extend"), "hero-plus-mini", "E"},
      {"split", gettext("Split"), "hero-scissors-mini", "S"},
      {"door", gettext("Door"), "hero-arrow-right-end-on-rectangle-mini", "D"},
      {"opening", gettext("Opening"), "hero-arrows-right-left-mini", "O"},
      {"place", gettext("Place device"), "hero-map-pin-mini", "P"}
    ]
  end

  # Other levels shown faintly under the edited one (`nil` is the exterior).
  defp ghost_level_ids(references, level_key) do
    for key <- references, key != level_key, do: drawn_level_id(key)
  end

  attr(:draft, Plan, required: true)
  attr(:analysis, Analysis, required: true)
  attr(:level_key, :string, required: true)
  attr(:selected, :any, required: true)
  attr(:selected_rectangle, :any, required: true)
  attr(:hidden, :any, required: true)
  attr(:references, :any, required: true)
  attr(:device_by_id, :map, required: true)

  # Exterior › exterior zones and levels (from the lowest) › rooms › rectangles.
  defp element_tree(assigns) do
    assigns = assign(assigns, :rows, tree_rows(assigns))

    ~H"""
    <ul id="plan-tree" class="max-h-[calc(100vh-12rem)] overflow-y-auto py-1 text-sm">
      <li
        :for={row <- @rows}
        class={[
          "flex items-center gap-1 pr-2",
          row.active? && "bg-accent-soft text-accent"
        ]}
        style={"padding-left: #{0.25 + row.depth * 0.9}rem"}
        data-tree={row.focus_key}
      >
        <button
          type="button"
          phx-click="toggle-visibility"
          phx-value-key={row.visibility_key}
          disabled={row.eye_disabled?}
          title={row.eye_title}
          class="shrink-0 rounded p-1 text-muted hover:text-foreground disabled:opacity-60"
          data-eye={if(row.visible?, do: "on", else: "off")}
        >
          <.icon
            name={if(row.visible?, do: "hero-eye-mini", else: "hero-eye-slash-mini")}
            class="size-4"
          />
        </button>
        <button
          type="button"
          phx-click="focus"
          phx-value-level={row.level}
          phx-value-zone={row.zone}
          phx-value-rectangle={row.rectangle}
          phx-value-device={row.device}
          class={["min-w-0 flex-1 truncate py-1 text-left", !row.visible? && "opacity-50"]}
        >
          <.icon name={row.icon} class="mr-1 size-4 text-muted" />{row.label}
          <span :if={row.detail} class="ml-1 text-xs text-muted">{row.detail}</span>
        </button>
      </li>
    </ul>
    """
  end

  defp tree_rows(assigns) do
    %{draft: draft, analysis: analysis, level_key: level_key} = assigns

    levels = Enum.sort_by(draft.levels, &Map.get(analysis.elevations, &1.id, 0.0))
    zones_by_level = Enum.group_by(draft.zones, & &1.level_id)

    exterior_rows =
      [level_row(@exterior, gettext("Exterior"), 0, "hero-globe-americas-mini", assigns)] ++
        Enum.flat_map(Map.get(zones_by_level, nil, []), &zone_rows(&1, @exterior, 1, assigns))

    level_rows =
      Enum.flat_map(levels, fn level ->
        [level_row(level.id, level.name, 1, "hero-square-3-stack-3d-mini", assigns)] ++
          Enum.flat_map(
            Map.get(zones_by_level, level.id, []),
            &zone_rows(&1, level.id, 2, assigns)
          )
      end)

    Enum.map(
      exterior_rows ++ level_rows,
      &Map.put(&1, :active?, active_row?(&1, level_key, assigns))
    )
  end

  defp level_row(key, name, depth, icon, assigns) do
    current? = key == assigns.level_key

    %{
      depth: depth,
      label: name,
      detail: nil,
      icon: icon,
      level: key,
      zone: nil,
      rectangle: nil,
      device: nil,
      focus_key: "level:#{key}",
      visibility_key: key,
      visible?: current? or MapSet.member?(assigns.references, key),
      eye_disabled?: current?,
      eye_title:
        if(current?,
          do: gettext("Edited level"),
          else: gettext("Show under the edited level")
        )
    }
  end

  defp zone_rows(zone, level_key, depth, assigns) do
    zone_key = "zone:#{zone.id}"
    zone_visible? = not MapSet.member?(assigns.hidden, zone_key)

    device_rows =
      for placement <- assigns.draft.placements, placement.zone_id == zone.id do
        placement_key = "placement:#{placement.device_id}"

        %{
          depth: depth + 1,
          label: device_label(assigns.device_by_id, placement.device_id),
          detail: nil,
          icon: "hero-map-pin-mini",
          level: level_key,
          zone: nil,
          rectangle: nil,
          device: placement.device_id,
          focus_key: placement_key,
          visibility_key: placement_key,
          visible?: zone_visible? and not MapSet.member?(assigns.hidden, placement_key),
          eye_disabled?: not zone_visible?,
          eye_title: gettext("Show or hide")
        }
      end

    [
      %{
        depth: depth,
        label: zone.name,
        detail: nil,
        icon: "hero-square-2-stack-mini",
        level: level_key,
        zone: zone.id,
        rectangle: nil,
        device: nil,
        focus_key: zone_key,
        visibility_key: zone_key,
        visible?: zone_visible?,
        eye_disabled?: false,
        eye_title: gettext("Show or hide")
      }
    ] ++
      for {rectangle, index} <- Enum.with_index(zone.rectangles) do
        rectangle_key = "rectangle:#{zone.id}:#{index}"

        %{
          depth: depth + 1,
          label: "#{rectangle.width} × #{rectangle.depth}",
          detail: "cm",
          icon: "hero-stop-mini",
          level: level_key,
          zone: zone.id,
          rectangle: index,
          device: nil,
          focus_key: rectangle_key,
          visibility_key: rectangle_key,
          visible?: zone_visible? and not MapSet.member?(assigns.hidden, rectangle_key),
          eye_disabled?: not zone_visible?,
          eye_title: gettext("Show or hide")
        }
      end ++ device_rows
  end

  defp device_label(device_by_id, device_id) do
    case Map.fetch(device_by_id, device_id) do
      {:ok, device} -> device.name
      :error -> device_id
    end
  end

  defp active_row?(%{device: device_id}, _level_key, assigns) when is_binary(device_id),
    do: assigns.selected == {:placement, device_id}

  defp active_row?(%{zone: nil, level: level}, level_key, _assigns), do: level == level_key

  defp active_row?(%{zone: zone, rectangle: nil}, _level_key, assigns),
    do: assigns.selected == {:zone, zone} and is_nil(assigns.selected_rectangle)

  defp active_row?(%{zone: zone, rectangle: index}, _level_key, assigns),
    do: assigns.selected == {:zone, zone} and assigns.selected_rectangle == index

  defp offsets, do: Enum.map(@offsets, fn {label, value} -> {label, value} end)
  defp grids, do: @grids

  @impl Phoenix.LiveView
  def render(%{draft: nil} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={gettext("New plan")} back={~p"/plan"} />
      <.card class="max-w-xl">
        <.form for={%{}} as={:plan} id="new-plan" phx-submit="create" class="flex items-end gap-3">
          <div class="flex-1">
            <label for="new-plan-name" class="mb-1 block text-sm font-medium">
              {gettext("Home")}
            </label>
            <input
              id="new-plan-name"
              name="plan[name]"
              placeholder="742 Evergreen Terrace"
              autofocus
              class="block w-full rounded-md border-0 bg-surface px-3 py-2 text-sm ring-1 ring-border ring-inset focus:ring-2 focus:ring-accent focus:outline-none"
            />
          </div>
          <Form.button type="submit" variant={:primary}>{gettext("Create")}</Form.button>
        </.form>
      </.card>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        zone: selected_zone(assigns),
        opening: selected_opening(assigns),
        placement: selected_placement(assigns),
        tabs: level_tabs(assigns.draft, assigns.analysis)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
      wide
    >
      <div class="mb-3 flex flex-wrap items-center gap-3">
        <.link
          navigate={~p"/plan/#{@draft.id}"}
          class="text-muted hover:text-foreground"
          title={gettext("Back")}
        >
          <.icon name="hero-arrow-left-mini" class="size-5" />
        </.link>
        <h1 class="text-xl font-semibold tracking-tight">{@page_title}</h1>
        <div class="ml-auto flex items-center gap-3">
          <.save_status status={@status} saved_at={@saved_at} />
          <Form.button id="plan-done" variant={:primary} phx-click="done">
            <.icon name="hero-check-mini" class="size-4" /> {gettext("Done")}
          </Form.button>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-4 xl:grid-cols-[15rem_minmax(0,1fr)_19rem]">
        <.card title={gettext("Elements")} padded={false} class="self-start xl:sticky xl:top-0">
          <.element_tree
            device_by_id={@device_by_id}
            draft={@draft}
            analysis={@analysis}
            level_key={@level_key}
            selected={@selected}
            selected_rectangle={@selected_rectangle}
            hidden={@hidden}
            references={@references}
          />
        </.card>

        <div class="min-w-0 space-y-3">
          <div class="flex flex-wrap items-center gap-2">
            <nav
              id="plan-tools"
              class="inline-flex flex-wrap rounded-md ring-1 ring-border ring-inset"
            >
              <button
                :for={{tool, label, icon, shortcut} <- tools()}
                type="button"
                phx-click="tool"
                phx-value-tool={tool}
                data-tool={tool}
                title={"#{label} (#{shortcut})"}
                disabled={tool == "rectangle" and is_nil(@zone)}
                class={[
                  "inline-flex items-center gap-1 px-3 py-1.5 text-sm first:rounded-l-md last:rounded-r-md disabled:opacity-40",
                  tool == @tool && "bg-accent-soft font-medium text-accent",
                  tool != @tool && "text-muted hover:text-foreground"
                ]}
              >
                <.icon name={icon} class="size-4" /> {label}
              </button>
            </nav>
            <div :if={@tool == "split"} class="inline-flex rounded-md ring-1 ring-border ring-inset">
              <button
                :for={
                  {axis, label} <- [vertical: gettext("Vertical"), horizontal: gettext("Horizontal")]
                }
                type="button"
                phx-click="axis"
                phx-value-axis={axis}
                class={[
                  "px-3 py-1.5 text-sm first:rounded-l-md last:rounded-r-md",
                  axis == @split_axis && "bg-accent-soft text-accent",
                  axis != @split_axis && "text-muted"
                ]}
              >
                {label}
              </button>
            </div>
            <div class="inline-flex rounded-md ring-1 ring-border ring-inset" id="plan-history">
              <button
                type="button"
                phx-click="key"
                phx-value-action="undo"
                disabled={@history == []}
                title={gettext("Undo (Ctrl+Z)")}
                class="px-2 py-1.5 text-muted hover:text-foreground disabled:opacity-40"
              >
                <.icon name="hero-arrow-uturn-left-mini" class="size-4" />
              </button>
              <button
                type="button"
                phx-click="key"
                phx-value-action="redo"
                disabled={@future == []}
                title={gettext("Redo (Ctrl+Shift+Z)")}
                class="px-2 py-1.5 text-muted hover:text-foreground disabled:opacity-40"
              >
                <.icon name="hero-arrow-uturn-right-mini" class="size-4" />
              </button>
            </div>
            <div class="inline-flex rounded-md ring-1 ring-border ring-inset" id="plan-zoom">
              <button
                type="button"
                phx-click={JS.dispatch("plan:zoom", to: "#plan-editor", detail: %{factor: 0.8})}
                title={gettext("Zoom in (+)")}
                class="px-2 py-1.5 text-muted hover:text-foreground"
              >
                <.icon name="hero-magnifying-glass-plus-mini" class="size-4" />
              </button>
              <button
                type="button"
                phx-click={JS.dispatch("plan:zoom", to: "#plan-editor", detail: %{factor: 1.25})}
                title={gettext("Zoom out (-)")}
                class="px-2 py-1.5 text-muted hover:text-foreground"
              >
                <.icon name="hero-magnifying-glass-minus-mini" class="size-4" />
              </button>
              <button
                type="button"
                phx-click={JS.dispatch("plan:fit", to: "#plan-editor")}
                title={gettext("Fit (F)")}
                class="px-2 py-1.5 text-sm text-muted hover:text-foreground"
              >
                {gettext("Fit")}
              </button>
            </div>
            <form
              id="plan-editor-toolbar-grid"
              phx-change="grid"
              class="ml-auto flex items-center gap-2 text-sm text-muted"
            >
              <label for="plan-grid">{gettext("Grid")}</label>
              <select
                id="plan-grid"
                name="grid"
                class="rounded-md border-0 bg-surface py-1 pr-7 pl-2 text-sm ring-1 ring-border ring-inset"
              >
                {Phoenix.HTML.Form.options_for_select(Enum.map(grids(), &{"#{&1} cm", &1}), @grid)}
              </select>
            </form>
          </div>

          <nav id="plan-levels" class="flex flex-wrap gap-2">
            <button
              :for={{key, name} <- @tabs}
              type="button"
              phx-click="level"
              phx-value-key={key}
              class={[
                "rounded-md px-3 py-1 text-sm ring-1 ring-inset",
                key == @level_key && "bg-accent-soft font-medium text-accent ring-accent",
                key != @level_key && "text-muted ring-border hover:text-foreground"
              ]}
            >
              {name}
            </button>
          </nav>

          <.card padded={false}>
            <p class="border-b border-border px-4 py-1.5 text-xs text-muted" id="plan-tool-hint">
              {tool_hint(@tool)}
              <span class="ml-1 opacity-70">{gettext("Wheel: zoom · Space + drag: pan")}</span>
            </p>
            <div
              id="plan-editor"
              phx-hook="PlanEditor"
              data-tool={@tool}
              data-grid={@grid}
              class="h-[calc(100vh-13rem)] min-h-96 overflow-hidden"
            >
              <PlanDrawing.level_drawing
                plan={@draft}
                analysis={@analysis}
                level_id={drawn_level_id(@level_key)}
                device_by_id={@device_by_id}
                location_by_id={@location_by_id}
                editable
                grid={@grid}
                hidden={@hidden}
                ghost_level_ids={ghost_level_ids(@references, @level_key)}
                selected_zone_id={@zone && @zone.id}
                selected_rectangle={@selected_rectangle}
                selected_opening={match?({:opening, _index}, @selected) && elem(@selected, 1)}
                selected_device_id={match?({:placement, _id}, @selected) && elem(@selected, 1)}
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
                <span class="flex-1">{warning.message}</span>
                <Form.button
                  :if={warning.kind == :orphan_zone}
                  size={:small}
                  phx-click="anchor"
                  phx-value-zone_id={warning.zone_id}
                >
                  {gettext("Anchor")}
                </Form.button>
                <Form.button
                  :if={warning.kind == :location_mismatch}
                  size={:small}
                  phx-click="set-device-location"
                  phx-value-device_id={warning.device_id}
                  title={gettext("Set the device location to the room's location")}
                >
                  {gettext("Set location")}
                </Form.button>
              </li>
            </ul>
          </.card>
        </div>

        <div class="space-y-4">
          <.card :if={@tool == "place"} title={gettext("Place a device")} id="plan-place-device">
            <.form for={%{}} as={:place} phx-change="choose-device">
              <select
                name="device_id"
                id="plan-place-device-select"
                class="block w-full rounded-md border-0 bg-surface px-3 py-2 text-sm ring-1 ring-border ring-inset"
              >
                <option value="">{gettext("Choose a device")}</option>
                {Phoenix.HTML.Form.options_for_select(
                  device_options(@device_by_id, @draft),
                  @placing_device_id
                )}
              </select>
            </.form>
            <p class="mt-2 text-xs text-muted">
              {gettext("Then click in a room. A device already on the plan moves there.")}
            </p>
          </.card>

          <.card :if={@placement} title={gettext("Device")} id="plan-selected-placement">
            <p class="mb-3 text-sm">
              <.link
                :if={@device_by_id[@placement.device_id]}
                navigate={~p"/devices/#{@placement.device_id}"}
                class="font-medium hover:text-accent"
              >
                {@device_by_id[@placement.device_id].name}
              </.link>
              <span :if={!@device_by_id[@placement.device_id]} class="text-warning">
                {gettext("%{id} (deleted device)", id: @placement.device_id)}
              </span>
              <span class="text-muted">· {zone_name(@draft, @placement.zone_id)}</span>
            </p>
            <.form
              for={%{}}
              as={:placement}
              phx-change="update-placement"
              class="grid grid-cols-2 gap-2 text-sm"
            >
              <label>
                {gettext("Anchored")}
                <select
                  name="placement[anchor]"
                  class="mt-1 block w-full rounded-md border-0 bg-surface py-1 pr-7 pl-2 ring-1 ring-border ring-inset"
                >
                  {Phoenix.HTML.Form.options_for_select(
                    [
                      {gettext("Floor"), "floor"},
                      {gettext("Wall"), "wall"},
                      {gettext("Floating"), "float"}
                    ],
                    Atom.to_string(@placement.anchor)
                  )}
                </select>
              </label>
              <label>
                {gettext("Height (cm)")}
                <input
                  type="number"
                  name="placement[height]"
                  value={@placement.height}
                  min="0"
                  disabled={@placement.anchor == :floor}
                  phx-debounce="400"
                  class="mt-1 block w-full rounded-md border-0 bg-surface px-2 py-1 ring-1 ring-border ring-inset disabled:opacity-50"
                />
              </label>
            </.form>
            <div class="mt-4 flex justify-end">
              <Form.button variant={:danger} size={:small} phx-click="remove-placement">
                <.icon name="hero-x-mark-micro" class="size-4" /> {gettext("Remove from plan")}
              </Form.button>
            </div>
          </.card>

          <.card :if={@zone} title={gettext("Room")} id="plan-selected-zone">
            <.form for={%{}} as={:zone} id="zone-form" phx-change="update-zone" class="space-y-3">
              <div>
                <label class="mb-1 block text-sm font-medium" for="zone-name">
                  {gettext("Name")}
                </label>
                <input
                  id="zone-name"
                  name="zone[name]"
                  value={@zone.name}
                  phx-debounce="400"
                  class="block w-full rounded-md border-0 bg-surface px-3 py-2 text-sm ring-1 ring-border ring-inset"
                />
              </div>
              <div>
                <label class="mb-1 block text-sm font-medium" for="zone-location">
                  {gettext("Location")}
                </label>
                <select
                  id="zone-location"
                  name="zone[location_id]"
                  class="block w-full rounded-md border-0 bg-surface px-3 py-2 text-sm ring-1 ring-border ring-inset"
                >
                  <option value="">{gettext("None")}</option>
                  {Phoenix.HTML.Form.options_for_select(@location_options, @zone.location_id)}
                </select>
              </div>
            </.form>
            <p class="mt-3 text-sm text-muted">
              {PlanDrawing.measure_label(@analysis.measures[@zone.id])}
            </p>
            <div id="plan-rectangles" class="mt-3 space-y-2">
              <p class="text-xs font-medium tracking-wide text-muted uppercase">
                {gettext("Dimensions (cm)")}
              </p>
              <.form
                :for={{rectangle, index} <- Enum.with_index(@zone.rectangles)}
                for={%{}}
                as={:rectangle}
                id={"rectangle-#{index}"}
                phx-change="set-rectangle-values"
                class={[
                  "rounded-md p-2 ring-1 ring-inset",
                  index == @selected_rectangle && "ring-accent",
                  index != @selected_rectangle && "ring-border"
                ]}
              >
                <input type="hidden" name="index" value={index} />
                <div class="grid grid-cols-4 gap-1 text-xs">
                  <label
                    :for={
                      {field, label} <- [
                        x: "x",
                        y: "y",
                        width: gettext("Width"),
                        depth: gettext("Depth")
                      ]
                    }
                    class="text-muted"
                  >
                    {label}
                    <input
                      type="number"
                      name={"rectangle[#{field}]"}
                      value={Map.fetch!(rectangle, field)}
                      step={@grid}
                      phx-debounce="500"
                      class="mt-0.5 block w-full rounded border-0 bg-surface px-1.5 py-1 text-foreground ring-1 ring-border ring-inset"
                    />
                  </label>
                </div>
                <button
                  :if={length(@zone.rectangles) > 1}
                  type="button"
                  phx-click="delete-rectangle"
                  phx-value-index={index}
                  class="mt-1 text-xs text-danger hover:underline"
                >
                  {gettext("Remove this rectangle")}
                </button>
              </.form>
            </div>
            <div class="mt-4 flex justify-end">
              <Form.button
                variant={:danger}
                size={:small}
                phx-click="delete-zone"
                data-confirm={gettext("Delete %{name}?", name: @zone.name)}
              >
                <.icon name="hero-trash-micro" class="size-4" /> {gettext("Delete")}
              </Form.button>
            </div>
          </.card>

          <.card :if={@opening} title={gettext("Door or opening")} id="plan-selected-opening">
            <.form for={%{}} as={:opening} phx-change="update-opening" class="space-y-3">
              <select
                name="opening[kind]"
                class="block w-full rounded-md border-0 bg-surface px-3 py-2 text-sm ring-1 ring-border ring-inset"
              >
                {Phoenix.HTML.Form.options_for_select(
                  [{gettext("Door"), "door"}, {gettext("Opening"), "opening"}],
                  Atom.to_string(@opening.kind)
                )}
              </select>
              <label class="block text-sm">
                {gettext("Width (cm)")}
                <input
                  type="number"
                  name="opening[width]"
                  value={@opening.width}
                  min="10"
                  phx-debounce="400"
                  class="mt-1 block w-full rounded-md border-0 bg-surface px-3 py-2 text-sm ring-1 ring-border ring-inset"
                />
              </label>
            </.form>
            <div class="mt-4 flex justify-end">
              <Form.button variant={:danger} size={:small} phx-click="delete-opening">
                <.icon name="hero-trash-micro" class="size-4" /> {gettext("Delete")}
              </Form.button>
            </div>
          </.card>

          <.card title={gettext("Levels")} padded={false} id="plan-levels-panel">
            <ul class="divide-y divide-border">
              <li :for={level <- @draft.levels} class="px-4 py-3">
                <.form
                  for={%{}}
                  as={:level}
                  phx-change="update-level"
                  class="grid grid-cols-2 gap-2 text-sm"
                >
                  <input type="hidden" name="level_id" value={level.id} />
                  <input
                    name="level[name]"
                    value={level.name}
                    phx-debounce="400"
                    class="col-span-2 rounded-md border-0 bg-surface px-2 py-1 ring-1 ring-border ring-inset"
                  />
                  <select
                    name="level[base_id]"
                    class="rounded-md border-0 bg-surface py-1 pr-7 pl-2 ring-1 ring-border ring-inset"
                  >
                    <option value="">{gettext("Reference")}</option>
                    {Phoenix.HTML.Form.options_for_select(
                      for(other <- @draft.levels, other.id != level.id, do: {other.name, other.id}),
                      level.base_id
                    )}
                  </select>
                  <select
                    :if={level.base_id}
                    name="level[offset]"
                    class="rounded-md border-0 bg-surface py-1 pr-7 pl-2 ring-1 ring-border ring-inset"
                  >
                    {Phoenix.HTML.Form.options_for_select(offsets(), level.offset)}
                  </select>
                </.form>
                <div class="mt-1 flex justify-between text-xs text-muted">
                  <span>{elevation(@analysis, level.id)}</span>
                  <button
                    type="button"
                    phx-click="delete-level"
                    phx-value-level_id={level.id}
                    data-confirm={gettext("Delete %{name} and its rooms?", name: level.name)}
                    class="text-danger hover:underline"
                  >
                    {gettext("Delete")}
                  </button>
                </div>
              </li>
            </ul>
            <.form
              for={%{}}
              as={:level}
              id="add-level"
              phx-submit="add-level"
              class="space-y-2 border-t border-border p-4 text-sm"
            >
              <input
                name="level[name]"
                placeholder={gettext("New level")}
                class="block w-full rounded-md border-0 bg-surface px-2 py-1 ring-1 ring-border ring-inset"
              />
              <div class="grid grid-cols-2 gap-2">
                <select
                  name="level[base_id]"
                  class="rounded-md border-0 bg-surface py-1 pr-7 pl-2 ring-1 ring-border ring-inset"
                >
                  <option value="">{gettext("Reference")}</option>
                  {Phoenix.HTML.Form.options_for_select(
                    Enum.map(@draft.levels, &{&1.name, &1.id}),
                    nil
                  )}
                </select>
                <select
                  name="level[offset]"
                  class="rounded-md border-0 bg-surface py-1 pr-7 pl-2 ring-1 ring-border ring-inset"
                >
                  {Phoenix.HTML.Form.options_for_select(offsets(), 1.0)}
                </select>
              </div>
              <label class="flex items-center gap-2 text-muted">
                <input
                  type="checkbox"
                  name="level[copy]"
                  value="true"
                  class="size-4 rounded border-border"
                />
                {gettext("Stacked: copy the base level's footprint")}
              </label>
              <Form.button type="submit" size={:small}>
                <.icon name="hero-plus-micro" class="size-4" /> {gettext("Add level")}
              </Form.button>
            </.form>
          </.card>

          <.card title={gettext("Home")} id="plan-settings">
            <.form for={%{}} as={:settings} phx-change="update-settings" class="space-y-3 text-sm">
              <input
                name="settings[name]"
                value={@draft.name}
                phx-debounce="400"
                class="block w-full rounded-md border-0 bg-surface px-3 py-2 ring-1 ring-border ring-inset"
              />
              <select
                name="settings[location_id]"
                class="block w-full rounded-md border-0 bg-surface px-3 py-2 ring-1 ring-border ring-inset"
              >
                <option value="">{gettext("No location")}</option>
                {Phoenix.HTML.Form.options_for_select(@location_options, @draft.location_id)}
              </select>
              <div class="grid grid-cols-2 gap-2">
                <label>
                  {gettext("Level height (cm)")}
                  <input
                    type="number"
                    name="settings[level_height]"
                    value={@draft.level_height}
                    min="100"
                    phx-debounce="400"
                    class="mt-1 block w-full rounded-md border-0 bg-surface px-2 py-1 ring-1 ring-border ring-inset"
                  />
                </label>
                <label>
                  {gettext("Wall height (cm)")}
                  <input
                    type="number"
                    name="settings[wall_height]"
                    value={@draft.wall_height}
                    min="100"
                    phx-debounce="400"
                    class="mt-1 block w-full rounded-md border-0 bg-surface px-2 py-1 ring-1 ring-border ring-inset"
                  />
                </label>
              </div>
              <div class="grid grid-cols-2 gap-2">
                <label>
                  {gettext("Ground on")}
                  <select
                    name="settings[ground_level_id]"
                    class="mt-1 block w-full rounded-md border-0 bg-surface py-1 pr-7 pl-2 ring-1 ring-border ring-inset"
                  >
                    <option value="">{gettext("Not set")}</option>
                    {Phoenix.HTML.Form.options_for_select(
                      Enum.map(@draft.levels, &{&1.name, &1.id}),
                      @draft.ground && @draft.ground.level_id
                    )}
                  </select>
                </label>
                <label>
                  {gettext("at (% of its height)")}
                  <input
                    type="number"
                    name="settings[ground_percent]"
                    value={@draft.ground && @draft.ground.percent}
                    min="0"
                    max="100"
                    phx-debounce="400"
                    class="mt-1 block w-full rounded-md border-0 bg-surface px-2 py-1 ring-1 ring-border ring-inset"
                  />
                </label>
              </div>
            </.form>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr(:status, :any, required: true)
  attr(:saved_at, :any, default: nil)

  defp save_status(assigns) do
    ~H"""
    <span
      id="plan-save-status"
      data-status={status_key(@status)}
      class="inline-flex items-center gap-2 text-sm"
    >
      <%= case @status do %>
        <% :saved -> %>
          <span class="size-2 rounded-full bg-success"></span>
          <span class="text-muted">
            {if @saved_at,
              do: gettext("Saved at %{time}", time: Calendar.strftime(@saved_at, "%H:%M:%S")),
              else: gettext("Saved")}
          </span>
        <% :pending -> %>
          <span class="size-2 animate-pulse rounded-full bg-warning"></span>
          <span class="text-muted">{gettext("Unsaved changes…")}</span>
          <button type="button" phx-click="save-now" class="text-accent hover:underline">
            {gettext("Save now")}
          </button>
        <% {:error, messages} -> %>
          <span class="size-2 rounded-full bg-danger"></span>
          <span class="text-danger">
            {gettext("Not saved: %{reasons}", reasons: Enum.join(messages, "; "))}
          </span>
      <% end %>
    </span>
    """
  end

  defp status_key(:saved), do: "saved"
  defp status_key(:pending), do: "pending"
  defp status_key({:error, _messages}), do: "error"

  defp elevation(analysis, level_id) do
    case Map.fetch(analysis.elevations, level_id) do
      {:ok, centimetres} -> "#{:erlang.float_to_binary(centimetres / 100, decimals: 2)} m"
      :error -> ""
    end
  end
end
