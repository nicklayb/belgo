defmodule BelgoWeb.Settings.Live do
  @moduledoc """
  Settings: the interface language, kept in the browser (automatic = the browser's;
  the `LocaleSetting` hook stores the choice in localStorage and the `belgo_locale`
  cookie, then reloads the page in that language), and the reload of the inventory
  files after hand edits, and the git versioning of the data directory
  (`Belgo.Versioning.Status`, read in the background since it asks the remote):
  uncommitted changes with a commit button, and a push button, each disabled when
  there is nothing to do. Results come back on the `versioning` topic.
  """

  use BelgoWeb, :live_view

  alias Belgo.Inventory
  alias Belgo.Versioning.Server, as: VersioningServer
  alias Belgo.Versioning.Status, as: VersioningStatus

  @listed_changes 10

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Belgo.PubSub, VersioningServer.topic())

    {:ok,
     socket
     |> assign(:page_title, gettext("Settings"))
     |> assign(:git_status, nil)
     |> assign(:pushing?, false)
     |> refresh_git_status()}
  end

  @impl Phoenix.LiveView
  def handle_async(:git_status, {:ok, status}, socket),
    do: {:noreply, assign(socket, :git_status, status)}

  def handle_async(:git_status, {:exit, reason}, socket),
    do:
      {:noreply,
       assign(socket, :git_status, %VersioningStatus{enabled?: true, error: inspect(reason)})}

  @impl Phoenix.LiveView
  def handle_info({:versioning_committed, _result}, socket),
    do: {:noreply, refresh_git_status(socket)}

  def handle_info({:versioning_pushed, result}, socket) do
    {:noreply,
     socket
     |> assign(:pushing?, false)
     |> put_push_flash(result)
     |> refresh_git_status()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("git-refresh", _params, socket), do: {:noreply, refresh_git_status(socket)}

  def handle_event("git-commit", _params, socket) do
    socket =
      case VersioningServer.commit_now() do
        {:ok, []} ->
          put_flash(socket, :info, gettext("Nothing to commit."))

        {:ok, paths} ->
          put_flash(socket, :info, gettext("Committed: %{paths}.", paths: Enum.join(paths, ", ")))

        {:error, message} ->
          put_flash(socket, :error, gettext("Commit failed: %{message}", message: message))

        :disabled ->
          put_flash(socket, :error, gettext("Git versioning is disabled."))
      end

    {:noreply, refresh_git_status(socket)}
  end

  def handle_event("git-push", _params, socket) do
    VersioningServer.push()
    {:noreply, assign(socket, :pushing?, true)}
  end

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

        <.git_card status={@git_status} pushing?={@pushing?} />

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

  # Read in a task: `ls-remote` may wait on the network.
  defp refresh_git_status(socket) do
    if connected?(socket) and Process.whereis(VersioningServer) do
      start_async(socket, :git_status, fn ->
        VersioningStatus.current(VersioningServer.info().directory)
      end)
    else
      socket
    end
  end

  defp put_push_flash(socket, {:ok, sha}),
    do: put_flash(socket, :info, gettext("Pushed %{commit}.", commit: sha))

  defp put_push_flash(socket, :up_to_date),
    do: put_flash(socket, :info, gettext("The remote is up to date."))

  defp put_push_flash(socket, {:error, message}),
    do: put_flash(socket, :error, gettext("Push failed: %{message}", message: message))

  attr(:status, VersioningStatus, default: nil)
  attr(:pushing?, :boolean, required: true)

  defp git_card(assigns) do
    assigns = assign(assigns, :listed_changes, @listed_changes)

    ~H"""
    <.card title={gettext("Git versioning")} id="git-versioning">
      <:actions>
        <Form.button
          size={:small}
          variant={:ghost}
          phx-click="git-refresh"
          title={gettext("Check again")}
        >
          <.icon name="hero-arrow-path-mini" class="size-4" />
          <span class="sr-only">{gettext("Check again")}</span>
        </Form.button>
      </:actions>
      <p :if={@status == nil} class="text-sm text-muted">{gettext("Checking…")}</p>
      <p :if={@status && !@status.enabled?} class="text-sm text-muted">
        {gettext("Disabled: add a git key to config.yaml to version the inventory files.")}
      </p>
      <div :if={@status && @status.enabled?} class="space-y-3 text-sm">
        <p :if={@status.error} class="font-mono text-xs break-all text-danger">{@status.error}</p>
        <p :if={!@status.repository?} class="text-muted">
          {gettext("The repository is created on the first commit.")}
        </p>
        <p :if={@status.last_commit} id="git-last-commit">
          <span class="text-muted">{gettext("Last commit:")}</span>
          <span class="font-mono">{@status.last_commit.sha}</span> {@status.last_commit.subject}
        </p>
        <div id="git-changes">
          <p :if={@status.changes == []} class="text-muted">{gettext("No uncommitted change.")}</p>
          <p :if={@status.changes != []} class="font-medium text-warning">
            {ngettext("1 uncommitted change", "%{count} uncommitted changes", length(@status.changes))}
          </p>
          <ul :if={@status.changes != []} class="mt-1 font-mono text-xs text-muted">
            <li :for={path <- Enum.take(@status.changes, @listed_changes)}>{path}</li>
            <li :if={length(@status.changes) > @listed_changes}>…</li>
          </ul>
        </div>
        <p id="git-remote" class="text-muted">
          <%= cond do %>
            <% @status.remote == nil -> %>
              {gettext("No remote configured (git.remote): nothing is pushed.")}
            <% @status.to_push? and @status.ahead -> %>
              {ngettext(
                "1 commit to push to %{remote}",
                "%{count} commits to push to %{remote}",
                @status.ahead,
                remote: @status.remote
              )}
            <% @status.to_push? -> %>
              {gettext("Commits to push to %{remote}.", remote: @status.remote)}
            <% true -> %>
              {gettext("%{remote} is up to date.", remote: @status.remote)}
          <% end %>
        </p>
        <div class="flex flex-wrap gap-2">
          <Form.button id="git-commit" phx-click="git-commit" disabled={@status.changes == []}>
            <.icon name="hero-check-mini" class="size-4" /> {gettext("Commit")}
          </Form.button>
          <Form.button
            id="git-push"
            phx-click="git-push"
            disabled={@pushing? or not @status.to_push?}
          >
            <.icon name="hero-arrow-up-tray-mini" class="size-4" />
            {if @pushing?, do: gettext("Pushing…"), else: gettext("Push")}
          </Form.button>
        </div>
      </div>
    </.card>
    """
  end

  defp language_name("fr"), do: "Français"
  defp language_name(_english), do: "English"
end
