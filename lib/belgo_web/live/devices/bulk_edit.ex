defmodule BelgoWeb.Devices.Live.BulkEdit do
  @moduledoc """
  Edits several devices at once (`Belgo.Inventory.BulkEdit`): kind, placement and
  metadata. The devices come from the `ids` query param (comma separated); the other
  params are the device list filter, restored when going back.
  """

  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Inventory
  alias Belgo.Inventory.BulkEdit
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.DeviceFilter
  alias Belgo.Inventory.MetadataLabels
  alias Belgo.Topology.Physical
  alias BelgoWeb.Format
  alias BelgoWeb.Live.Mutation

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    requested_ids =
      params
      |> Map.get("ids", "")
      |> String.split(",", trim: true)

    {:ok,
     socket
     |> assign(:page_title, gettext("Edit devices"))
     |> assign(:requested_ids, requested_ids)
     |> assign(:back_path, ~p"/devices?#{DeviceFilter.to_query_params(DeviceFilter.new(params))}")
     |> assign_form(%{})
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    snapshot = socket.assigns.snapshot
    requested = MapSet.new(socket.assigns.requested_ids)

    socket
    |> assign(
      :devices,
      snapshot.devices
      |> Enum.filter(&MapSet.member?(requested, &1.id))
      |> Enum.sort_by(&String.downcase(&1.name))
    )
    |> assign(:location_options, Physical.location_options(snapshot))
    |> assign(:metadata_labels, MetadataLabels.list(snapshot))
    |> assign(:metadata_values, MetadataLabels.values(snapshot))
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"bulk_edit" => params}, socket),
    do: {:noreply, assign_form(socket, params, :validate)}

  def handle_event("save", %{"bulk_edit" => params}, socket) do
    device_ids = Enum.map(socket.assigns.devices, & &1.id)

    case Inventory.update_devices(device_ids, params, Mutation.options(socket)) do
      {:ok, devices} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           ngettext("1 device updated.", "%{count} devices updated.", length(devices))
         )
         |> push_navigate(to: socket.assigns.back_path)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}

      {:error, {:device, device_id}, %Ecto.Changeset{} = changeset, _changes} ->
        {:noreply, put_flash(socket, :error, describe_device_error(socket, device_id, changeset))}

      error ->
        {:noreply, put_flash(socket, :error, Mutation.describe_error(error))}
    end
  end

  defp assign_form(socket, params, action \\ nil) do
    form =
      params
      |> BulkEdit.changeset()
      |> Map.put(:action, action)
      |> to_form()

    assign(socket, :form, form)
  end

  defp describe_device_error(socket, device_id, changeset) do
    name =
      Enum.find_value(socket.assigns.devices, device_id, &(&1.id == device_id && &1.name))

    messages =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, _options} -> message end)
      |> Enum.flat_map(fn {field, field_messages} ->
        Enum.map(List.flatten([field_messages]), &"#{field} #{inspect_message(&1)}")
      end)
      |> Enum.join(", ")

    gettext("%{name} cannot be saved: %{messages}. Nothing was changed.",
      name: name,
      messages: messages
    )
  end

  defp inspect_message(message) when is_binary(message), do: message
  defp inspect_message(message), do: inspect(message)

  defp placement_options do
    [
      {gettext("Keep current"), :keep},
      {gettext("In a location"), :location},
      {gettext("Portable"), :portable},
      {gettext("Unplaced"), :unplaced}
    ]
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
      <.page_header title={@page_title} back={@back_path}>
        <:subtitle>
          {gettext("Empty fields keep each device's value. Conflicting values are overwritten.")}
        </:subtitle>
      </.page_header>

      <.card :if={@devices == []}>
        <.empty_state icon="hero-server" title={gettext("No device selected")}>
          {gettext("Select devices in the list first.")}
        </.empty_state>
      </.card>

      <.form
        :if={@devices != []}
        for={@form}
        id="bulk-edit-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-6"
      >
        <.card title={ngettext("1 device", "%{count} devices", length(@devices))}>
          <ul id="bulk-edit-devices" class="flex flex-wrap gap-2">
            <li
              :for={device <- @devices}
              class="rounded-md bg-surface-muted px-2 py-1 text-sm ring-1 ring-border"
            >
              <.device_link device={device} />
            </li>
          </ul>
        </.card>

        <.card title={gettext("Kind and placement")}>
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
            <Form.input
              field={@form[:kind]}
              type="select"
              label={gettext("Kind")}
              prompt={gettext("Keep current")}
              options={Format.options(Device.kinds())}
            />
            <Form.input
              field={@form[:placement]}
              type="select"
              label={gettext("Placement")}
              options={placement_options()}
            />
            <Form.input
              :if={to_string(@form[:placement].value) == "location"}
              field={@form[:location_id]}
              type="select"
              label={gettext("Location")}
              prompt={gettext("Choose a location")}
              options={@location_options}
            />
          </div>
        </.card>

        <.card title={gettext("Metadata")}>
          <:actions>
            <Form.button
              size={:small}
              name="bulk_edit[metadata_sort][]"
              value="new"
              phx-click={JS.dispatch("change")}
            >
              <.icon name="hero-plus-micro" class="size-4" /> {gettext("Add")}
            </Form.button>
          </:actions>
          <p class="text-sm text-muted">
            {gettext(
              "Each entry is set on every device: it replaces the value of the same label, other entries are kept."
            )}
          </p>
          <.metadata_datalists labels={@metadata_labels} values_by_label={@metadata_values} />
          <div class="mt-3 space-y-3">
            <.inputs_for :let={entry_form} field={@form[:metadata]}>
              <div class="flex flex-col gap-2 sm:flex-row sm:items-start">
                <input type="hidden" name="bulk_edit[metadata_sort][]" value={entry_form.index} />
                <Form.input
                  field={entry_form[:label]}
                  placeholder={gettext("Label")}
                  list="metadata-labels"
                  phx-mounted={Form.blank?(entry_form[:label]) && JS.focus()}
                  class="sm:w-56"
                />
                <Form.input
                  field={entry_form[:value]}
                  placeholder={gettext("Value")}
                  list={metadata_values_list(@metadata_values, entry_form[:label].value)}
                  class="flex-1"
                />
                <Form.button
                  variant={:danger}
                  size={:small}
                  name="bulk_edit[metadata_drop][]"
                  value={entry_form.index}
                  phx-click={JS.dispatch("change")}
                  class="sm:mt-1.5"
                  title={gettext("Remove")}
                >
                  <.icon name="hero-trash-micro" class="size-4" />
                </Form.button>
              </div>
            </.inputs_for>
          </div>
          <input type="hidden" name="bulk_edit[metadata_drop][]" />
          <Form.errors errors={Form.visible_errors(@form[:metadata])} />
        </.card>

        <div class="flex justify-end gap-2">
          <Form.button navigate={@back_path}>{gettext("Cancel")}</Form.button>
          <Form.button type="submit" variant={:primary} phx-disable-with={gettext("Saving…")}>
            {ngettext("Update 1 device", "Update %{count} devices", length(@devices))}
          </Form.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
