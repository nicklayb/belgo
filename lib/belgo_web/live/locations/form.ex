defmodule BelgoWeb.Locations.Live.Form do
  @moduledoc "Creates or edits a location."

  use BelgoWeb, :live_view

  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.Suggestion
  alias Belgo.Inventory.Location
  alias Belgo.Topology.Physical
  alias BelgoWeb.Format
  alias BelgoWeb.Live.RecordForm

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    discovered = fetch_discovered(socket.assigns.discovery.correlation, params)

    defaults =
      if discovered,
        do: Suggestion.location_params(discovered, socket.assigns.snapshot),
        else: Map.take(params, ["parent_id"])

    socket = RecordForm.mount(socket, :locations, params, defaults, ~p"/locations")

    parent_options =
      socket.assigns.snapshot
      |> Physical.location_options()
      |> Enum.reject(fn {_label, id} ->
        socket.assigns[:record] && id == socket.assigns.record.id
      end)

    {:ok,
     socket
     |> assign(:parent_options, parent_options)
     |> assign(:discovered, discovered)
     |> assign(:page_title, page_title(socket.assigns[:record], discovered))}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"location" => params}, socket),
    do: {:noreply, RecordForm.validate(socket, :locations, params)}

  def handle_event("save", %{"location" => params}, socket),
    do: {:noreply, RecordForm.save(socket, :locations, params, ~p"/locations")}

  defp fetch_discovered(correlation, %{"discovered" => id}) do
    case Correlation.fetch_location(correlation, id) do
      {:ok, discovered} -> discovered
      {:error, :not_found} -> nil
    end
  end

  defp fetch_discovered(_correlation, _params), do: nil

  defp page_title(nil, nil), do: gettext("New location")
  defp page_title(nil, _discovered), do: gettext("Claim a discovered location")
  defp page_title(%Location{name: name}, _discovered), do: gettext("Edit %{name}", name: name)

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={@page_title} back={~p"/locations"} />
      <.card :if={@discovered} title={gettext("Reported by providers")} class="mb-6" padded={false}>
        <.observation_list observations={@discovered.observations} />
      </.card>
      <.form for={@form} id="location-form" phx-change="validate" phx-submit="save">
        <.card>
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Form.input field={@form[:name]} label={gettext("Name")} autofocus={!@record} />
            <Form.input
              field={@form[:id]}
              label={gettext("Identifier")}
              hint={gettext("Used in files and references. Defaults to the name.")}
              disabled={@record != nil}
            />
            <Form.input
              field={@form[:kind]}
              type="select"
              label={gettext("Kind")}
              options={Format.options(Location.kinds())}
            />
            <Form.input
              field={@form[:parent_id]}
              type="select"
              label={gettext("Inside")}
              prompt={gettext("Nothing (top level)")}
              options={@parent_options}
            />
            <Form.input
              field={@form[:home_assistant_id]}
              label={gettext("Home Assistant")}
              placeholder="area/living_room"
              hint={gettext("Linked floor (floor/<id>) or area (area/<id>), set when claimed.")}
              class="sm:col-span-2"
            />
            <Form.input
              field={@form[:notes]}
              type="textarea"
              label={gettext("Notes")}
              rows="3"
              class="sm:col-span-2"
            />
          </div>
        </.card>
        <div class="mt-6 flex justify-end gap-2">
          <Form.button navigate={~p"/locations"}>{gettext("Cancel")}</Form.button>
          <Form.button type="submit" variant={:primary} phx-disable-with={gettext("Saving…")}>
            {gettext("Save")}
          </Form.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
