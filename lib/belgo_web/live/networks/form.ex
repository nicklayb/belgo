defmodule BelgoWeb.Networks.Live.Form do
  @moduledoc "Creates or edits a network."

  use BelgoWeb, :live_view

  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.Suggestion
  alias Belgo.Inventory.Network
  alias BelgoWeb.Live.RecordForm

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    discovered = fetch_discovered(socket.assigns.discovery.correlation, params)
    defaults = if discovered, do: Suggestion.network_params(discovered), else: %{}
    socket = RecordForm.mount(socket, :networks, params, defaults, ~p"/networks")

    {:ok,
     socket
     |> assign(:discovered, discovered)
     |> assign(:page_title, page_title(socket.assigns[:record], discovered))}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"network" => params}, socket),
    do: {:noreply, RecordForm.validate(socket, :networks, params)}

  def handle_event("save", %{"network" => params}, socket),
    do: {:noreply, RecordForm.save(socket, :networks, params, ~p"/networks")}

  defp fetch_discovered(correlation, %{"discovered" => id}) do
    case Correlation.fetch_network(correlation, id) do
      {:ok, discovered} -> discovered
      {:error, :not_found} -> nil
    end
  end

  defp fetch_discovered(_correlation, _params), do: nil

  defp page_title(nil, nil), do: gettext("New network")
  defp page_title(nil, _discovered), do: gettext("Claim a discovered network")
  defp page_title(%Network{name: name}, _discovered), do: gettext("Edit %{name}", name: name)

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={@page_title} back={~p"/networks"} />
      <.card :if={@discovered} title={gettext("Reported by providers")} class="mb-6" padded={false}>
        <.observation_list observations={@discovered.observations} />
      </.card>
      <.form for={@form} id="network-form" phx-change="validate" phx-submit="save">
        <.card>
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Form.input field={@form[:name]} label={gettext("Name")} autofocus={!@record} />
            <Form.input
              field={@form[:id]}
              label={gettext("Identifier")}
              hint={gettext("Used in files and references. Defaults to the name.")}
              disabled={@record != nil}
            />
            <Form.input
              field={@form[:cidr]}
              label={gettext("Range (CIDR)")}
              placeholder="192.168.1.0/24"
            />
            <Form.input field={@form[:gateway]} label={gettext("Gateway")} placeholder="192.168.1.1" />
            <Form.input field={@form[:vlan]} type="number" label={gettext("VLAN")} min="1" max="4094" />
            <Form.input
              field={@form[:dhcp_start]}
              label={gettext("DHCP range start")}
              placeholder="192.168.1.100"
              hint={gettext("Dynamic pool. Devices outside of it are listed apart in Discovery.")}
            />
            <Form.input
              field={@form[:dhcp_end]}
              label={gettext("DHCP range end")}
              placeholder="192.168.1.199"
            />
            <Form.input
              field={@form[:domain]}
              label={gettext("Domain")}
              placeholder="home.lan"
              hint={gettext("Appended to hostnames in DNS records.")}
            />
            <Form.input
              field={@form[:notes]}
              type="textarea"
              label={gettext("Notes")}
              rows="3"
              class="sm:col-span-2"
            />
          </div>
        </.card>
        <div class="mt-6 flex justify-end gap-2">
          <Form.button navigate={~p"/networks"}>{gettext("Cancel")}</Form.button>
          <Form.button type="submit" variant={:primary} phx-disable-with={gettext("Saving…")}>
            {gettext("Save")}
          </Form.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
