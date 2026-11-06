defmodule BelgoWeb.VirtualIps.Live.Form do
  @moduledoc """
  Creates or edits a virtual IP. `?discovered=<id>` prefills it from a device found
  by Discovery (its address and the DNS names pointing to it).
  """

  use BelgoWeb, :live_view

  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.Suggestion
  alias Belgo.Inventory.VirtualIp
  alias BelgoWeb.Format
  alias BelgoWeb.Live.RecordForm

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    discovered = fetch_discovered(socket.assigns.discovery.correlation, params)

    defaults =
      if discovered,
        do: Suggestion.virtual_ip_params(discovered, socket.assigns.snapshot),
        else: Map.take(params, ["owner_id"])

    socket = RecordForm.mount(socket, :virtual_ips, params, defaults, ~p"/virtual-ips")

    {:ok,
     socket
     |> assign(:discovered, discovered)
     |> assign(:page_title, page_title(socket.assigns[:record], discovered))}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"virtual_ip" => params}, socket),
    do: {:noreply, RecordForm.validate(socket, :virtual_ips, params)}

  def handle_event("save", %{"virtual_ip" => params}, socket),
    do: {:noreply, RecordForm.save(socket, :virtual_ips, params, ~p"/virtual-ips")}

  defp fetch_discovered(correlation, %{"discovered" => id}) do
    case Correlation.fetch_device(correlation, id) do
      {:ok, discovered} -> discovered
      {:error, :not_found} -> nil
    end
  end

  defp fetch_discovered(_correlation, _params), do: nil

  defp page_title(nil, nil), do: gettext("New virtual IP")
  defp page_title(nil, _discovered), do: gettext("Claim as a virtual IP")
  defp page_title(%VirtualIp{name: name}, _discovered), do: gettext("Edit %{name}", name: name)

  defp dns_names_value(%Phoenix.HTML.FormField{value: names}) when is_list(names),
    do: Enum.join(names, ", ")

  defp dns_names_value(%Phoenix.HTML.FormField{value: value}), do: value

  defp device_options(snapshot) do
    snapshot.devices
    |> Enum.sort_by(&String.downcase(&1.name))
    |> Enum.map(&{&1.name, &1.id})
  end

  defp network_options(snapshot),
    do: Enum.map(snapshot.networks, &{"#{&1.name} (#{&1.cidr})", &1.id})

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={@page_title} back={~p"/virtual-ips"}>
        <:subtitle>
          {gettext(
            "An address that is not a machine: a load balancer (MetalLB, kube-vip) or a floating address (keepalived)."
          )}
        </:subtitle>
      </.page_header>
      <.card :if={@discovered} title={gettext("Reported by providers")} class="mb-6" padded={false}>
        <.observation_list observations={@discovered.observations} />
      </.card>
      <.form for={@form} id="virtual-ip-form" phx-change="validate" phx-submit="save">
        <.card>
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Form.input field={@form[:name]} label={gettext("Name")} autofocus={!@record} />
            <Form.input
              field={@form[:id]}
              label={gettext("Identifier")}
              hint={gettext("Used in files and references. Defaults to the name.")}
              disabled={@record != nil}
            />
            <Form.input field={@form[:ip]} label={gettext("IP address")} placeholder="192.168.1.110" />
            <Form.input
              field={@form[:kind]}
              type="select"
              label={gettext("Kind")}
              options={Format.options(VirtualIp.kinds())}
            />
            <Form.input
              field={@form[:network_id]}
              type="select"
              label={gettext("Network")}
              prompt={gettext("Found from the address")}
              options={network_options(@snapshot)}
            />
            <Form.input
              field={@form[:owner_id]}
              type="select"
              label={gettext("Owner")}
              prompt={gettext("None")}
              options={device_options(@snapshot)}
              hint={gettext("The cluster or host answering for this address.")}
            />
            <Form.input
              field={@form[:dns_names]}
              value={dns_names_value(@form[:dns_names])}
              label={gettext("DNS names")}
              placeholder="photos, registry.k8s.home.arpa"
              hint={
                gettext(
                  "Comma separated. A name without a dot gets the network domain. Pushed as Unbound host overrides."
                )
              }
              class="sm:col-span-2"
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
          <Form.button navigate={~p"/virtual-ips"}>{gettext("Cancel")}</Form.button>
          <Form.button type="submit" variant={:primary} phx-disable-with={gettext("Saving…")}>
            {gettext("Save")}
          </Form.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
