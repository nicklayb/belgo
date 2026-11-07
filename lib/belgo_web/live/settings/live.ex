defmodule BelgoWeb.Settings.Live do
  @moduledoc """
  Personal settings, kept in the browser: the interface language (automatic = the
  browser's). The `LocaleSetting` hook stores the choice in localStorage and the
  `belgo_locale` cookie, then reloads the page in that language.
  """

  use BelgoWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, :page_title, gettext("Settings"))}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={gettext("Settings")}>
        <:subtitle>{gettext("Saved in this browser.")}</:subtitle>
      </.page_header>

      <.card title={gettext("Language")} class="max-w-xl">
        <label for="locale-setting" class="mb-1 block text-sm font-medium">
          {gettext("Interface language")}
        </label>
        <select
          id="locale-setting"
          phx-hook="LocaleSetting"
          phx-update="ignore"
          data-current={@locale}
          class="block w-full rounded-md border-0 bg-surface px-3 py-2 text-sm ring-1 ring-border ring-inset"
        >
          <option value="">{gettext("Automatic (browser language)")}</option>
          <option value="en" lang="en">English</option>
          <option value="fr" lang="fr">Français</option>
        </select>
        <p class="mt-2 text-xs text-muted">
          {gettext("Now: %{language}.", language: language_name(@locale))}
        </p>
      </.card>
    </Layouts.app>
    """
  end

  defp language_name("fr"), do: "Français"
  defp language_name(_english), do: "English"
end
