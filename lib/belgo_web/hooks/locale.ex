defmodule BelgoWeb.Hooks.Locale do
  @moduledoc """
  Sets the Gettext locale of the LiveView process: the `locale` connect param (the
  choice stored in the browser) when supported, else the one the request resolved
  (session, see `BelgoWeb.Plugs.Locale`).
  """

  alias BelgoWeb.Locale

  @doc false
  def on_mount(:default, _params, session, socket) do
    locale =
      Locale.supported(connect_locale(socket)) ||
        Locale.supported(session["locale"]) || Locale.default()

    Gettext.put_locale(BelgoWeb.Gettext, locale)
    {:cont, Phoenix.Component.assign(socket, :locale, locale)}
  end

  defp connect_locale(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: Phoenix.LiveView.get_connect_params(socket)["locale"],
      else: nil
  end
end
