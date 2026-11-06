defmodule BelgoWeb.Locations.Live.Index do
  @moduledoc "Physical map: the location tree and the devices found in each place."

  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Inventory
  alias Belgo.Topology.DeviceNode
  alias Belgo.Topology.Physical
  alias Belgo.Topology.Physical.LocationNode
  alias BelgoWeb.Format
  alias BelgoWeb.Live.Mutation

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Locations"))
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    assign(socket, :map, Physical.build(socket.assigns.snapshot))
  end

  @impl Phoenix.LiveView
  def handle_event("delete", %{"id" => id}, socket) do
    case Inventory.delete(:locations, id, Mutation.options(socket)) do
      {:ok, location} ->
        {:noreply, put_flash(socket, :info, gettext("%{name} deleted.", name: location.name))}

      error ->
        {:noreply, put_flash(socket, :error, Mutation.describe_error(error))}
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
      <.page_header title={gettext("Locations")}>
        <:subtitle>
          {gettext("Where every device physically is. Guests follow their host.")}
        </:subtitle>
        <:actions>
          <Form.button variant={:primary} navigate={~p"/locations/new"}>
            <.icon name="hero-plus-mini" class="size-4" /> {gettext("New location")}
          </Form.button>
        </:actions>
      </.page_header>

      <.card :if={@map.roots == []}>
        <.empty_state icon="hero-map-pin" title={gettext("No location yet")}>
          {gettext("Start with your home, then add rooms inside it.")}
        </.empty_state>
      </.card>

      <div class="space-y-4">
        <.location_node :for={node <- @map.roots} node={node} />
      </div>

      <div class="mt-6 grid grid-cols-1 gap-4 md:grid-cols-2">
        <.card :if={@map.portable != []} title={gettext("Portable")}>
          <.device_tree nodes={@map.portable} />
        </.card>
        <.card :if={@map.unplaced != []} title={gettext("Unplaced")}>
          <.device_tree nodes={@map.unplaced} />
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr(:node, LocationNode, required: true)
  attr(:depth, :integer, default: 0)

  defp location_node(assigns) do
    assigns =
      assign(assigns, :device_count, Enum.sum_by(assigns.node.devices, &DeviceNode.count/1))

    ~H"""
    <section
      id={@node.location.id}
      class={[
        "scroll-mt-6",
        @depth == 0 && "rounded-xl border border-border bg-surface p-4 shadow-xs",
        @depth > 0 && "border-l-2 border-border pl-4"
      ]}
    >
      <header class="group flex items-center gap-2">
        <.icon name={Format.location_icon(@node.location)} class="size-5 text-accent" />
        <h2 class="font-semibold">
          <.link navigate={~p"/locations/#{@node.location.id}"} class="hover:text-accent">
            {@node.location.name}
          </.link>
        </h2>
        <span class="text-xs text-muted">{Format.label(@node.location.kind)}</span>
        <.badge :if={@device_count > 0}>{@device_count}</.badge>
        <div class="ml-auto flex gap-1 opacity-100 transition-opacity sm:opacity-0 sm:group-hover:opacity-100 sm:focus-within:opacity-100">
          <Form.button
            variant={:ghost}
            size={:small}
            navigate={~p"/locations/new?parent_id=#{@node.location.id}"}
            title={gettext("Add a location inside")}
          >
            <.icon name="hero-plus-micro" class="size-4" />
          </Form.button>
          <Form.button
            variant={:ghost}
            size={:small}
            navigate={~p"/locations/#{@node.location.id}/edit"}
            title={gettext("Edit")}
          >
            <.icon name="hero-pencil-square-micro" class="size-4" />
          </Form.button>
          <Form.button
            variant={:danger}
            size={:small}
            phx-click="delete"
            phx-value-id={@node.location.id}
            data-confirm={gettext("Delete %{name}?", name: @node.location.name)}
            title={gettext("Delete")}
          >
            <.icon name="hero-trash-micro" class="size-4" />
          </Form.button>
        </div>
      </header>
      <div :if={@node.devices != []} class="mt-2 ml-7"><.device_tree nodes={@node.devices} /></div>
      <div :if={@node.locations != []} class="mt-3 ml-2 space-y-3">
        <.location_node :for={child <- @node.locations} node={child} depth={@depth + 1} />
      </div>
    </section>
    """
  end
end
