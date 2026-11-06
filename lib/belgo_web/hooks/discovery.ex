defmodule BelgoWeb.Hooks.Discovery do
  @moduledoc """
  Assigns the discovery state (`discovery`) and the menu badges (`navigation_badges`)
  and keeps them current. Views implementing `c:assign_discovery/1` recompute what they
  derive from the discovery when it changes.
  """

  alias Belgo.Discovery
  alias BelgoWeb.Navigation

  @doc "Recomputes the assigns derived from `socket.assigns.discovery`."
  @callback assign_discovery(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()

  @optional_callbacks assign_discovery: 1

  @doc false
  def on_mount(:default, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket), do: Discovery.subscribe()

    socket =
      socket
      |> assign_state(Discovery.state())
      |> Phoenix.LiveView.attach_hook(:discovery, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  @doc """
  Recomputes the menu counters from the snapshot and the discovery, once both are
  assigned. Called by both the inventory and the discovery hooks.
  """
  @spec assign_navigation_badges(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_navigation_badges(%{assigns: %{snapshot: snapshot, discovery: discovery}} = socket),
    do:
      Phoenix.Component.assign(socket, :navigation_badges, Navigation.badges(snapshot, discovery))

  def assign_navigation_badges(socket),
    do: Phoenix.Component.assign(socket, :navigation_badges, %{})

  defp handle_info({:discovery_changed, state}, socket) do
    socket = assign_state(socket, state)

    if function_exported?(socket.view, :assign_discovery, 1),
      do: {:halt, socket.view.assign_discovery(socket)},
      else: {:halt, socket}
  end

  defp handle_info(_message, socket), do: {:cont, socket}

  defp assign_state(socket, state) do
    socket
    |> Phoenix.Component.assign(:discovery, state)
    |> assign_navigation_badges()
  end
end
