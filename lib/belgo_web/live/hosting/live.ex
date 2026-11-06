defmodule BelgoWeb.Hosting.Live do
  @moduledoc "Virtualisation tree: hosts and the guests running on them."

  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Topology.Hosting
  alias Belgo.Topology.Hosting.Group
  alias Belgo.Topology.Hosting.Host
  alias BelgoWeb.Format

  @platform_icons %{
    proxmox: "hero-server-stack",
    docker: "hero-cube",
    kubernetes: "hero-squares-2x2"
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Hosting"))
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket),
    do: assign(socket, :groups, Hosting.groups(socket.assigns.snapshot))

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={gettext("Hosting")}>
        <:subtitle>
          {gettext("Proxmox, Docker and Kubernetes hosts with what runs on them.")}
        </:subtitle>
      </.page_header>

      <.card :if={@groups == []}>
        <.empty_state icon="hero-rectangle-stack" title={gettext("No host yet")}>
          {gettext("Declare a platform on a device, or host a device on another one.")}
        </.empty_state>
      </.card>

      <div class="space-y-8">
        <section :for={%Group{} = group <- @groups} id={"platform-#{group.platform || "other"}"}>
          <h2 class="mb-3 flex items-center gap-2 text-sm font-semibold tracking-wide text-muted uppercase">
            <.icon name={platform_icon(group.platform)} class="size-5 text-accent" />
            {platform_label(group.platform)}
            <.badge>{length(group.hosts)}</.badge>
          </h2>
          <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <.host_card :for={host <- group.hosts} host={host} />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr(:host, Host, required: true)

  defp host_card(assigns) do
    ~H"""
    <.card>
      <div class="flex flex-wrap items-center gap-2">
        <.device_link device={@host.device} class="text-base" />
        <.platform_badges platforms={@host.device.platforms} />
        <span class="ml-auto text-xs text-muted">
          {ngettext("1 guest", "%{count} guests", length(@host.guests))}
        </span>
      </div>
      <p :if={@host.hosts != []} class="mt-0.5 text-xs text-muted">
        {gettext("%{runs_as} on %{hosts}",
          runs_as: Format.label(@host.device.virtualization),
          hosts: Enum.map_join(@host.hosts, " › ", & &1.name)
        )}
      </p>
      <ul :if={@host.guests != []} class="mt-3 space-y-1">
        <li :for={guest <- @host.guests} class="flex flex-wrap items-center gap-2 text-sm">
          <.device_link device={guest} />
          <span class="text-xs text-muted">{Format.label(guest.virtualization)}</span>
          <.platform_badges platforms={guest.platforms} />
        </li>
      </ul>
      <p :if={@host.guests == []} class="mt-3 text-sm text-muted">
        {gettext("Nothing runs here yet.")}
      </p>
    </.card>
    """
  end

  defp platform_label(nil), do: gettext("Other hosts")
  defp platform_label(platform), do: Format.label(platform)

  defp platform_icon(platform), do: Map.get(@platform_icons, platform, "hero-rectangle-stack")
end
