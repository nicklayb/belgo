defmodule BelgoWeb.Discovery.Live.ClaimDnsName do
  @moduledoc """
  Claims a DNS name reported by a provider as a DNS name of a device interface or of
  a virtual IP. The interface or virtual IP holding the address the name resolves to
  is preselected; any other one with an address can be chosen instead.
  """

  @behaviour BelgoWeb.Hooks.Discovery
  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Discovery
  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.DnsNames
  alias Belgo.Discovery.DnsNames.DiscoveredDnsName
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.VirtualIp
  alias BelgoWeb.FlashMessage
  alias BelgoWeb.Live.Mutation

  @device_placeholder "%{device}"

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Claim a DNS name"))
     |> assign(:dns_name_id, id)
     |> assign(:dns_name, nil)
     |> assign(selection: nil, owner: nil, interfaces: [], destination: nil)
     |> assign_inventory()}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    socket
    |> assign(:candidates, candidates(socket.assigns.snapshot))
    |> assign_discovery()
  end

  # The name disappears from the discovery once claimed: the page keeps the last one.
  @impl BelgoWeb.Hooks.Discovery
  def assign_discovery(socket) do
    case Correlation.fetch_dns_name(
           socket.assigns.discovery.correlation,
           socket.assigns.dns_name_id
         ) do
      {:ok, dns_name} ->
        socket
        |> assign(:dns_name, dns_name)
        |> assign_selection(socket.assigns.selection || suggested_selection(dns_name))

      {:error, :not_found} ->
        socket
    end
  end

  @impl Phoenix.LiveView
  def handle_event("select", %{"claim" => params}, socket) do
    target = Map.get(params, "target", "")

    interface_index =
      if target == elem(socket.assigns.selection, 0),
        do: parse_index(Map.get(params, "interface_index")),
        else: nil

    {:noreply, assign_selection(socket, {target, interface_index})}
  end

  def handle_event("claim", _params, socket) do
    dns_name = socket.assigns.dns_name

    case Discovery.claim_dns_name(
           dns_name,
           claim_target(socket.assigns),
           Mutation.options(socket)
         ) do
      {:ok, record} ->
        {:noreply,
         socket
         |> put_flash(:info, claimed_message(dns_name, record))
         |> push_navigate(to: ~p"/")}

      error ->
        {:noreply, put_flash(socket, :error, describe_error(error))}
    end
  end

  defp claim_target(%{owner: %VirtualIp{id: id}}), do: {:virtual_ips, id}

  defp claim_target(%{owner: %Device{id: id}, selection: {_target, index}}),
    do: {:devices, id, index}

  defp claimed_message(dns_name, record) do
    message =
      gettext("%{name} added to %{device}.", name: dns_name.name, device: @device_placeholder)

    FlashMessage.linked(message, @device_placeholder, record.name, record_path(record))
  end

  defp record_path(%Device{id: id}), do: ~p"/devices/#{id}"
  defp record_path(%VirtualIp{id: id}), do: ~p"/virtual-ips/#{id}"

  defp suggested_selection(%DiscoveredDnsName{virtual_ip_id: nil} = dns_name),
    do: {target_value(:devices, dns_name.device_id), dns_name.interface_index}

  defp suggested_selection(dns_name),
    do: {target_value(:virtual_ips, dns_name.virtual_ip_id), nil}

  defp target_value(collection, id), do: "#{collection}:#{id}"

  defp parse_target("devices:" <> id), do: {:devices, id}
  defp parse_target("virtual_ips:" <> id), do: {:virtual_ips, id}
  defp parse_target(_value), do: nil

  defp parse_index(value) do
    case Integer.parse(value || "") do
      {index, ""} -> index
      _invalid -> nil
    end
  end

  # The destination is the virtual IP, or a valid interface of the device: the
  # requested one, else the one holding the name's address, else the first one.
  defp assign_selection(socket, {target, interface_index}) do
    with {collection, id} <- parse_target(target),
         {:ok, record} <- Snapshot.fetch(socket.assigns.snapshot, collection, id) do
      assign_destination(socket, target, record, interface_index)
    else
      _missing ->
        assign(socket, selection: {target, nil}, owner: nil, interfaces: [], destination: nil)
    end
  end

  defp assign_destination(socket, target, %VirtualIp{} = virtual_ip, _interface_index) do
    assign(socket,
      selection: {target, nil},
      owner: virtual_ip,
      interfaces: [],
      destination: virtual_ip
    )
  end

  defp assign_destination(socket, target, %Device{} = device, interface_index) do
    interfaces = DnsNames.addressed_interfaces(device)
    indexes = Enum.map(interfaces, &elem(&1, 1))
    address = socket.assigns.dns_name && socket.assigns.dns_name.ip

    index =
      cond do
        interface_index in indexes -> interface_index
        match = Enum.find(interfaces, &(elem(&1, 0).ip == address)) -> elem(match, 1)
        true -> List.first(indexes)
      end

    assign(socket,
      selection: {target, index},
      owner: device,
      interfaces: interfaces,
      destination:
        Enum.find_value(interfaces, fn {interface, position} -> position == index && interface end)
    )
  end

  defp candidates(snapshot) do
    virtual_ips =
      snapshot.virtual_ips
      |> Enum.sort_by(&String.downcase(&1.name))
      |> Enum.map(&{"#{&1.name} (#{&1.ip})", target_value(:virtual_ips, &1.id)})

    devices =
      snapshot.devices
      |> Enum.filter(&(DnsNames.addressed_interfaces(&1) != []))
      |> Enum.sort_by(&String.downcase(&1.name))
      |> Enum.map(&{&1.name, target_value(:devices, &1.id)})

    Enum.reject(
      [{gettext("Virtual IPs"), virtual_ips}, {gettext("Devices"), devices}],
      &match?({_label, []}, &1)
    )
  end

  defp interface_options(interfaces) do
    Enum.map(interfaces, fn {interface, index} ->
      {"#{interface.name || gettext("Interface %{position}", position: index + 1)} – #{interface.ip}",
       index}
    end)
  end

  defp stored_name(dns_name, snapshot, destination),
    do: DnsNames.stored_name(dns_name, DnsNames.network_domain(snapshot, destination))

  defp describe_error({:error, :record, %Ecto.Changeset{} = changeset, _changes}) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _options} -> message end)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp describe_error({:error, :record, :interface_without_address, _changes}),
    do: gettext("This interface has no address.")

  defp describe_error(error), do: Mutation.describe_error(error)

  defp flatten_errors(errors) when is_map(errors),
    do: Enum.flat_map(errors, fn {_field, nested} -> flatten_errors(nested) end)

  defp flatten_errors(errors) when is_list(errors), do: Enum.flat_map(errors, &flatten_errors/1)
  defp flatten_errors(message) when is_binary(message), do: [message]

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={gettext("Claim a DNS name")} back={~p"/"}>
        <:subtitle :if={@dns_name}>
          <span class="font-mono">{@dns_name.name}</span>
          → <span class="font-mono">{@dns_name.ip}</span>
        </:subtitle>
      </.page_header>

      <.card :if={!@dns_name}>
        <.empty_state icon="hero-globe-alt" title={gettext("This DNS name is no longer unclaimed")}>
          {gettext("It was claimed, or no provider reports it anymore.")}
        </.empty_state>
      </.card>

      <.card :if={@dns_name} class="max-w-2xl">
        <.form
          :let={form}
          for={
            to_form(
              %{"target" => elem(@selection, 0), "interface_index" => elem(@selection, 1)},
              as: :claim
            )
          }
          id="claim-dns-name"
          phx-change="select"
          phx-submit="claim"
          class="space-y-4"
        >
          <p class="text-sm text-muted">
            {gettext("Reported by")}
            <.source_badges observations={@dns_name.observations} />
          </p>
          <Form.input
            field={form[:target]}
            type="select"
            label={gettext("Device or virtual IP")}
            options={@candidates}
            prompt={gettext("Choose a device or a virtual IP")}
          />
          <Form.input
            :if={@interfaces != []}
            field={form[:interface_index]}
            type="select"
            label={gettext("Interface")}
            options={interface_options(@interfaces)}
          />
          <div :if={@destination} id="claim-summary" class="space-y-2 text-sm">
            <p>
              {gettext("Saved as")}
              <span class="font-mono text-accent">
                {stored_name(@dns_name, @snapshot, @destination)}
              </span>
              {gettext("on %{device}.", device: @owner.name)}
            </p>
            <p :if={@destination.ip != @dns_name.ip} id="claim-address-warning" class="text-warning">
              {gettext(
                "%{name} resolves to %{current} today: the next push makes it resolve to %{address}.",
                name: @dns_name.name,
                current: @dns_name.ip,
                address: @destination.ip
              )}
            </p>
          </div>
          <div class="flex justify-end gap-2">
            <Form.button navigate={~p"/"}>{gettext("Cancel")}</Form.button>
            <Form.button type="submit" variant={:primary} disabled={is_nil(@destination)}>
              {gettext("Claim")}
            </Form.button>
          </div>
        </.form>
      </.card>
    </Layouts.app>
    """
  end
end
