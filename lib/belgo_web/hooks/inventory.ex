defmodule BelgoWeb.Hooks.Inventory do
  @moduledoc """
  Assigns the inventory `snapshot` and keeps it current: when the inventory changes,
  the snapshot is replaced and the view's `c:assign_inventory/1` recomputes the data
  derived from it.
  """

  alias Belgo.Inventory

  @doc "Recomputes the assigns derived from `socket.assigns.snapshot`."
  @callback assign_inventory(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()

  @doc false
  def on_mount(:default, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket), do: Inventory.subscribe()

    socket =
      socket
      |> Phoenix.Component.assign(:snapshot, Inventory.snapshot())
      |> Phoenix.LiveView.attach_hook(:inventory, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp handle_info({:inventory_changed, snapshot}, socket) do
    socket =
      socket
      |> Phoenix.Component.assign(:snapshot, snapshot)
      |> BelgoWeb.Hooks.Discovery.assign_navigation_badges()

    if function_exported?(socket.view, :assign_inventory, 1),
      do: {:halt, socket.view.assign_inventory(socket)},
      else: {:halt, socket}
  end

  defp handle_info(_message, socket), do: {:cont, socket}
end
