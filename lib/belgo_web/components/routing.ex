defmodule BelgoWeb.Components.Routing do
  @moduledoc "Components rendering network links and paths."

  use Phoenix.Component
  use Gettext, backend: BelgoWeb.Gettext
  use BelgoWeb, :verified_routes

  import BelgoWeb.Components.Core

  alias Belgo.Topology.Routing.Hop
  alias Belgo.Topology.Routing.Link
  alias BelgoWeb.Format

  attr(:link, Link, required: true)

  @doc "How a device is connected: port or Wi-Fi, the source, and the AP lock."
  def link_details(assigns) do
    ~H"""
    <span class="inline-flex flex-wrap items-center gap-1 text-xs text-muted">
      <span :if={@link.wireless?} class="inline-flex items-center gap-1">
        <.icon name="hero-wifi-micro" class="size-3.5" /> {@link.ssid || gettext("Wi-Fi")}
      </span>
      <span :if={!@link.wireless? && @link.port}>{gettext("port %{port}", port: @link.port)}</span>
      <.badge :if={@link.locked_to_ap == true} tone={:accent}>{gettext("Locked to AP")}</.badge>
      <.badge :if={@link.locked_to_ap == false}>{gettext("Roaming")}</.badge>
      <.badge :if={@link.source != :inventory} tone={:success}>
        {gettext("live")} · {Format.label(@link.source)}
      </.badge>
    </span>
    """
  end

  attr(:hops, :list, required: true)

  @doc "A network path: the device, then every node up to the gateway."
  def network_path(assigns) do
    ~H"""
    <ol class="flex flex-wrap items-center gap-1 text-sm">
      <li
        :for={{%Hop{} = hop, position} <- Enum.with_index(@hops)}
        class="inline-flex items-center gap-1"
      >
        <.icon :if={position > 0} name="hero-arrow-long-right-mini" class="size-4 text-muted" />
        <.link
          :if={hop.device}
          navigate={~p"/devices/#{hop.device.id}"}
          class={["hover:text-accent", position == 0 && "font-medium"]}
        >
          {hop.name}
        </.link>
        <span :if={!hop.device} class="text-muted italic">{hop.name}</span>
      </li>
    </ol>
    """
  end
end
