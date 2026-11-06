defmodule BelgoWeb.Routing.Live do
  @moduledoc """
  The network routing: gateway, switches (managed or not) and access points as a
  tree, with the devices connected to each, live from the providers when they know.
  """

  @behaviour BelgoWeb.Hooks.Discovery
  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Topology.Routing
  alias Belgo.Topology.Routing.Node
  alias BelgoWeb.Format

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Routing"))
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket), do: assign_routing(socket)

  @impl BelgoWeb.Hooks.Discovery
  def assign_discovery(socket), do: assign_routing(socket)

  defp assign_routing(socket) do
    snapshot = socket.assigns.snapshot
    links = Routing.links(snapshot, socket.assigns.discovery.correlation.uplinks)
    assign(socket, :roots, Routing.build(snapshot, links))
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
      <.page_header title={gettext("Routing")}>
        <:subtitle>
          {gettext("Gateway, switches and access points, with what is connected to them.")}
        </:subtitle>
        <:actions>
          <Form.button navigate={~p"/devices/new?kind=network&network_role=switch"}>
            <.icon name="hero-plus-mini" class="size-4" /> {gettext("New switch")}
          </Form.button>
        </:actions>
      </.page_header>

      <.card :if={@roots == []}>
        <.empty_state icon="hero-share" title={gettext("No network device yet")}>
          {gettext(
            "Give network devices a role (gateway, switch, access point), or claim them from Discovery."
          )}
        </.empty_state>
      </.card>

      <div class="space-y-4">
        <.card :for={node <- @roots}>
          <.routing_node node={node} />
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr(:node, Node, required: true)
  attr(:depth, :integer, default: 0)

  defp routing_node(assigns) do
    ~H"""
    <div class={[@depth > 0 && "mt-3 ml-3 border-l-2 border-border pl-4"]}>
      <div class="flex flex-wrap items-center gap-2">
        <.icon name={Format.role_icon(@node.device.network_role)} class="size-5 text-accent" />
        <.link navigate={~p"/devices/#{@node.device.id}"} class="font-semibold hover:text-accent">
          {@node.device.name}
        </.link>
        <span class="text-xs text-muted">{Format.label(@node.device.network_role)}</span>
        <.link_details :if={@node.link} link={@node.link} />
        <.badge :if={@node.clients != []} class="ml-auto">
          {ngettext("1 device", "%{count} devices", length(@node.clients))}
        </.badge>
      </div>
      <ul
        :if={@node.clients != []}
        class="mt-2 ml-7 grid grid-cols-1 gap-1 sm:grid-cols-2 lg:grid-cols-3"
      >
        <li :for={{client, link} <- @node.clients} class="flex min-w-0 flex-col">
          <.device_link device={client} class="text-sm" />
          <.link_details link={link} />
        </li>
      </ul>
      <.routing_node :for={child <- @node.children} node={child} depth={@depth + 1} />
    </div>
    """
  end
end
