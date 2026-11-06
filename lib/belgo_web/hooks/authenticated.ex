defmodule BelgoWeb.Hooks.Authenticated do
  @moduledoc "Assigns `current_user` to LiveViews from the session."

  alias BelgoWeb.Authentication

  @doc false
  def on_mount(:default, _params, session, socket) do
    case Authentication.user_from_session(session) do
      {:ok, user} -> {:cont, Phoenix.Component.assign(socket, :current_user, user)}
      :error -> {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end
end
