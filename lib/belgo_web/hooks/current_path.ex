defmodule BelgoWeb.Hooks.CurrentPath do
  @moduledoc "Assigns `current_path` on every navigation, used to highlight the menu."

  @doc false
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> Phoenix.Component.assign(:current_path, "/")
      |> Phoenix.LiveView.attach_hook(:current_path, :handle_params, fn _params, uri, socket ->
        {:cont, Phoenix.Component.assign(socket, :current_path, URI.parse(uri).path)}
      end)

    {:cont, socket}
  end
end
