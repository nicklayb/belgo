defmodule BelgoWeb.Settings.Live do
  @moduledoc """
  Settings: the interface language, kept in the browser (automatic = the browser's;
  the `LocaleSetting` hook stores the choice in localStorage and the `belgo_locale`
  cookie, then reloads the page in that language), and the reload of the inventory
  files after hand edits.
  """

  use BelgoWeb, :live_view

  alias Belgo.Inventory

  @impl Phoenix.LiveView
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, :page_title, gettext("Settings"))}

  @impl Phoenix.LiveView
  def handle_event("reload", _params, socket) do
    case Inventory.reload() do
      :ok ->
        {:noreply, put_flash(socket, :info, gettext("Inventory reloaded from disk."))}

      {:error, {:invalid_inventory, messages}} ->
        message = Enum.join([gettext("The files are invalid, nothing changed:") | messages], "\n")
        {:noreply, put_flash(socket, :error, message)}
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
      <.page_header title={gettext("Settings")} />

      <div class="max-w-xl space-y-6">
        <.card title={gettext("Language")}>
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
            {gettext("Saved in this browser.")}
          </p>
        </.card>

        <.card title={gettext("Inventory files")} id="inventory-files">
          <p class="text-sm text-muted">
            {gettext(
              "After editing the inventory files by hand, re-read them: invalid files change nothing."
            )}
          </p>
          <Form.button phx-click="reload" class="mt-3">
            <.icon name="hero-arrow-path-mini" class="size-4" /> {gettext("Reload files")}
          </Form.button>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp language_name("fr"), do: "Français"
  defp language_name(_english), do: "English"
end
