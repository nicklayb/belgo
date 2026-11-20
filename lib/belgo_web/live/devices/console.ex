defmodule BelgoWeb.Devices.Live.Console do
  @moduledoc """
  The Intel AMT serial console of a device (`Belgo.Amt.Sol`), in a terminal
  (xterm.js, `AmtConsole` hook, loaded only here). The session belongs to the
  current user and outlives the page: coming back replays its scrollback. Without a
  session, the page asks the AMT account to open one.

  Protocol with the hook: `attach` (subscribes, replies with the scrollback in
  base64), `input` (base64 keystrokes), `amt-output` (base64 output pushed to the
  hook), `amt-closed`. Console content is never logged.
  """

  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Amt.Sol
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Snapshot
  alias BelgoWeb.Components.Amt, as: AmtComponents
  alias BelgoWeb.Live.Amt, as: LiveAmt
  alias BelgoWeb.Live.PortScans

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    username = socket.assigns.current_user.username

    {:ok,
     socket
     |> assign(
       device_id: id,
       username: username,
       open?: Sol.open?(username, id),
       closed_reason: nil,
       offset: 0,
       session_key: 0,
       amt_request: nil,
       amt_error: nil,
       amt_form_key: 0,
       idle_timeout_minutes: LiveAmt.idle_timeout_minutes()
     )
     |> PortScans.subscribe()
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    case Snapshot.fetch(socket.assigns.snapshot, :devices, socket.assigns.device_id) do
      {:ok, device} ->
        socket
        |> assign(page_title: gettext("Console of %{name}", name: device.name), device: device)
        |> PortScans.scan(Device.ip_addresses(device))

      {:error, :not_found} ->
        socket
        |> put_flash(:error, gettext("This device no longer exists."))
        |> push_navigate(to: ~p"/devices")
    end
  end

  @impl Phoenix.LiveView
  def handle_event("attach", _params, socket) do
    case Sol.attach(socket.assigns.username, socket.assigns.device_id) do
      {:ok, content, offset} ->
        {:reply, %{data: Base.encode64(content)}, assign(socket, offset: offset, open?: true)}

      {:error, :closed} ->
        {:reply, %{data: ""}, assign(socket, :open?, false)}
    end
  end

  def handle_event("input", %{"data" => data}, socket) do
    with {:ok, bytes} <- Base.decode64(data),
         do: Sol.input(socket.assigns.username, socket.assigns.device_id, bytes)

    {:noreply, socket}
  end

  def handle_event("close", _params, socket) do
    Sol.close(socket.assigns.username, socket.assigns.device_id)
    {:noreply, socket}
  end

  def handle_event("amt-request", _params, socket),
    do: {:noreply, assign(socket, amt_request: :console, amt_error: nil)}

  def handle_event("amt-cancel", _params, socket) do
    {:noreply,
     socket
     |> assign(amt_request: nil)
     |> update(:amt_form_key, &(&1 + 1))}
  end

  def handle_event("amt-submit", %{"amt" => params}, socket) do
    device = socket.assigns.device

    with %{} = detection <- LiveAmt.detection(socket.assigns.address_scans, device),
         {:ok, credentials} <- LiveAmt.credentials(params),
         {:ok, _opened} <-
           LiveAmt.open_console(socket.assigns.username, device, detection, credentials) do
      {:noreply,
       socket
       |> assign(open?: true, closed_reason: nil, offset: 0, amt_request: nil)
       |> update(:amt_form_key, &(&1 + 1))
       # A new terminal element: its hook mounts and attaches to the new session.
       |> update(:session_key, &(&1 + 1))}
    else
      nil -> {:noreply, amt_error(socket, gettext("AMT is not detected on this device."))}
      {:error, message} when is_binary(message) -> {:noreply, amt_error(socket, message)}
      {:error, reason} -> {:noreply, amt_error(socket, LiveAmt.describe_error(reason))}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:amt_sol_output, offset, data}, socket) do
    if offset > socket.assigns.offset do
      {:noreply,
       socket
       |> assign(:offset, offset)
       |> push_event("amt-output", %{data: Base.encode64(data)})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:amt_sol_closed, reason}, socket) do
    {:noreply,
     socket
     |> assign(open?: false, closed_reason: reason)
     |> push_event("amt-closed", %{})}
  end

  def handle_info({:port_scan_changed, address_scans}, socket),
    do: {:noreply, PortScans.changed(socket, address_scans)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp amt_error(socket, message) do
    socket
    |> assign(:amt_error, message)
    |> update(:amt_form_key, &(&1 + 1))
  end

  @impl Phoenix.LiveView
  def render(%{device: _device} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
      wide
    >
      <.page_header
        title={gettext("Console of %{name}", name: @device.name)}
        back={~p"/devices/#{@device.id}"}
      >
        <:subtitle>
          {gettext("Intel AMT serial over LAN. Closes after %{minutes} min without input.",
            minutes: @idle_timeout_minutes
          )}
        </:subtitle>
        <:actions>
          <Form.button :if={@open?} id="amt-console-close" variant={:danger} phx-click="close">
            <.icon name="hero-x-mark-mini" class="size-4" /> {gettext("Close the console")}
          </Form.button>
          <Form.button
            :if={!@open? and LiveAmt.detection(@address_scans, @device)}
            id="amt-console-connect"
            variant={:primary}
            phx-click="amt-request"
          >
            <.icon name="hero-command-line-mini" class="size-4" /> {LiveAmt.request_label(:console)}
          </Form.button>
        </:actions>
      </.page_header>

      <p :if={@closed_reason} id="amt-console-closed" class="mb-3 text-sm text-muted">
        {closed_message(@closed_reason)}
      </p>
      <p
        :if={!@open? and !@closed_reason and !LiveAmt.detection(@address_scans, @device)}
        class="mb-3 text-sm text-muted"
      >
        {gettext("Looking for Intel AMT on this device…")}
      </p>

      <div
        :if={@open? or @closed_reason}
        id={"amt-console-#{@session_key}"}
        phx-hook="AmtConsole"
        phx-update="ignore"
        class="h-[70vh] overflow-hidden rounded-xl border border-border bg-black p-2"
      >
        <div data-terminal class="size-full"></div>
      </div>

      <AmtComponents.credentials_modal
        :if={@amt_request}
        request={@amt_request}
        device={@device}
        error={@amt_error}
        form_key={@amt_form_key}
      />
    </Layouts.app>
    """
  end

  def render(assigns), do: ~H""

  defp closed_message(:manual), do: gettext("Console closed.")

  defp closed_message(:idle),
    do: gettext("Console closed after a long time without input.")

  defp closed_message({:exit_status, status}),
    do: gettext("amtterm stopped (exit status %{status}).", status: status)
end
