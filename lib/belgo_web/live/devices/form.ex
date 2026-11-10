defmodule BelgoWeb.Devices.Live.Form do
  @moduledoc "Creates or edits a device, its placement and its interfaces."

  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Discovery
  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.Matching
  alias Belgo.Discovery.ReservedAddresses
  alias Belgo.Discovery.State
  alias Belgo.Discovery.Suggestion
  alias Belgo.Inventory
  alias Belgo.Inventory.AddressAllocation
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Interface
  alias Belgo.Inventory.MetadataLabels
  alias Belgo.Inventory.Snapshot
  alias Belgo.Topology.Physical
  alias BelgoWeb.Format
  alias BelgoWeb.Live.Mutation

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    case fetch_device(socket.assigns.snapshot, socket.assigns.live_action, params) do
      {:ok, device} ->
        discovered = fetch_discovered(socket.assigns.discovery.correlation, device, params)

        socket =
          socket
          |> assign(:device, device)
          |> assign(:discovered, discovered)
          |> assign_attach_form(discovered)
          |> assign(:page_title, page_title(device, discovered))
          |> assign(:address_suggestions, %{})
          |> assign_inventory()
          |> assign_form(initial_params(discovered, socket.assigns.snapshot, params))

        {:ok, socket}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, gettext("This device no longer exists."))
         |> push_navigate(to: ~p"/devices")}
    end
  end

  # Devices able to host guests (with a platform: Proxmox, Docker, Kubernetes), named
  # with their platforms; the device's current host stays listed even without one.
  defp host_options(other_devices, device) do
    current_host_id = device && device.host_id

    for host <- other_devices, Device.host?(host) or host.id == current_host_id do
      case host.platforms do
        [] ->
          {host.name, host.id}

        platforms ->
          {"#{host.name} (#{Enum.map_join(platforms, ", ", &Format.label/1)})", host.id}
      end
    end
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    snapshot = socket.assigns.snapshot
    device_id = socket.assigns.device && socket.assigns.device.id

    other_devices =
      snapshot.devices
      |> Enum.reject(&(&1.id == device_id))
      |> Enum.sort_by(&String.downcase(&1.name))

    socket
    |> assign(:location_options, Physical.location_options(snapshot))
    |> assign(:host_options, host_options(other_devices, socket.assigns.device))
    |> assign(
      :switch_options,
      for(device <- other_devices, device.kind == :network, do: {device.name, device.id})
    )
    |> assign(:network_options, Enum.map(snapshot.networks, &{"#{&1.name} (#{&1.cidr})", &1.id}))
    |> assign(:metadata_labels, MetadataLabels.list(snapshot))
    |> assign(:metadata_values, MetadataLabels.values(snapshot))
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"device" => params}, socket) do
    {params, suggestions} = suggest_addresses(socket, params)

    {:noreply,
     socket
     |> assign_form(params, :validate)
     |> update(:address_suggestions, &Map.merge(&1, suggestions))}
  end

  def handle_event("attach", %{"attach" => %{"device_id" => device_id}}, socket)
      when device_id != "" do
    case Discovery.attach(socket.assigns.discovered, device_id, Mutation.options(socket)) do
      {:ok, device} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Interfaces added to %{name}.", name: device.name))
         |> push_navigate(to: ~p"/devices/#{device.id}")}

      error ->
        {:noreply, put_flash(socket, :error, Mutation.describe_error(error))}
    end
  end

  def handle_event("attach", _params, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Choose a device first."))}

  def handle_event("save", %{"device" => params}, socket) do
    case reservation_conflicts(socket, params) do
      [] -> {:noreply, save_device(socket, params)}
      _conflicts -> {:noreply, assign_form(socket, params, :validate)}
    end
  end

  defp save_device(socket, params) do
    case save(socket, params) do
      {:ok, device} ->
        socket
        |> put_flash(:info, gettext("%{name} saved.", name: device.name))
        |> push_navigate(to: ~p"/devices/#{device.id}")

      {:error, :record, %Ecto.Changeset{} = changeset, _changes} ->
        socket
        |> assign(:form, to_form(changeset, action: :validate))
        |> assign(:placement, current_placement(changeset, params))

      error ->
        put_flash(socket, :error, Mutation.describe_error(error))
    end
  end

  defp save(%{assigns: %{device: nil}} = socket, params),
    do: Inventory.create(:devices, params, Mutation.options(socket))

  defp save(%{assigns: %{device: device}} = socket, params),
    do: Inventory.update(:devices, device.id, params, Mutation.options(socket))

  # Shown while the field still holds the suggested address.
  defp address_hint(suggestions, interface_form) do
    current_ip = interface_form[:ip].value

    case Map.fetch(suggestions, interface_form.index) do
      {:ok, %{ip: ^current_ip, range: range}} ->
        gettext("First free address of %{range} (%{start} – %{end}).",
          range: range.name,
          start: range.start,
          end: range.end
        )

      _none ->
        nil
    end
  end

  # Addresses from the logical ranges of the device kind (see AddressAllocation).
  defp suggest_addresses(socket, params) do
    snapshot = socket.assigns.snapshot
    device_id = socket.assigns.device && socket.assigns.device.id

    used =
      AddressAllocation.used_addresses(
        snapshot,
        State.observations(socket.assigns.discovery),
        device_id
      )

    previous_kind = Ecto.Changeset.get_field(socket.assigns.form.source, :kind)

    AddressAllocation.suggest_params(params, previous_kind, snapshot, used,
      add_interface: socket.assigns.device == nil
    )
  end

  # Reserved interfaces must not take an address a provider reserved for another MAC.
  defp reservation_conflicts(socket, params) do
    socket.assigns.snapshot
    |> Inventory.change(:devices, socket.assigns.device, params)
    |> Ecto.Changeset.apply_changes()
    |> ReservedAddresses.conflicts(State.observations(socket.assigns.discovery))
  end

  defp assign_form(socket, params, action \\ nil) do
    changeset =
      socket.assigns.snapshot
      |> Inventory.change(:devices, socket.assigns.device, params)
      |> add_reservation_errors(State.observations(socket.assigns.discovery))

    socket
    |> assign(:form, to_form(changeset, action: action))
    |> assign(:placement, current_placement(changeset, params))
    |> assign(:range_suggestions, range_suggestions(socket, changeset))
  end

  # Offered (not applied) for interfaces outside the ranges of the device kind.
  defp range_suggestions(socket, changeset) do
    snapshot = socket.assigns.snapshot
    device_id = socket.assigns.device && socket.assigns.device.id
    observations = State.observations(socket.assigns.discovery)

    AddressAllocation.suggest_interfaces(
      snapshot,
      Ecto.Changeset.get_field(changeset, :kind),
      Ecto.Changeset.get_field(changeset, :interfaces),
      AddressAllocation.used_addresses(snapshot, observations, device_id)
    )
  end

  defp add_reservation_errors(changeset, observations) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> ReservedAddresses.conflicts(observations)
    |> Enum.reduce(changeset, &Ecto.Changeset.add_error(&2, :interfaces, &1))
  end

  defp current_placement(_changeset, %{"placement" => placement}) when placement != "",
    do: placement

  defp current_placement(changeset, _params) do
    changeset
    |> Ecto.Changeset.apply_changes()
    |> Device.placement_mode()
    |> Atom.to_string()
  end

  defp fetch_device(_snapshot, :new, _params), do: {:ok, nil}
  defp fetch_device(snapshot, :edit, %{"id" => id}), do: Snapshot.fetch(snapshot, :devices, id)

  defp fetch_discovered(correlation, nil, %{"discovered" => id}) do
    case Correlation.fetch_device(correlation, id) do
      {:ok, discovered} -> discovered
      {:error, :not_found} -> nil
    end
  end

  defp fetch_discovered(_correlation, _device, _params), do: nil

  defp assign_attach_form(socket, nil), do: assign(socket, :attach, nil)

  defp assign_attach_form(socket, discovered) do
    devices = Enum.sort_by(socket.assigns.snapshot.devices, &String.downcase(&1.name))
    best = Matching.best_device(discovered, devices)
    selected_id = with {device, _score} <- best, do: device.id

    assign(socket, :attach, %{
      form: to_form(%{"device_id" => selected_id}, as: :attach),
      options: Enum.map(devices, &{&1.name, &1.id}),
      best: best
    })
  end

  defp initial_params(nil, _snapshot, params), do: Map.take(params, ["kind", "network_role"])

  defp initial_params(discovered, snapshot, _params),
    do: Suggestion.device_params(discovered, snapshot)

  defp page_title(nil, nil), do: gettext("New device")
  defp page_title(nil, _discovered), do: gettext("Claim a discovered device")
  defp page_title(%Device{name: name}, _discovered), do: gettext("Edit %{name}", name: name)

  defp network_role_set?(form), do: form[:network_role].value not in [nil, ""]

  defp switch?(form), do: to_string(form[:network_role].value) == "switch"

  defp list_value(values) when is_list(values), do: Enum.join(values, ", ")
  defp list_value(value), do: value

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header
        title={@page_title}
        back={if @device, do: ~p"/devices/#{@device.id}", else: ~p"/devices"}
      />

      <.card :if={@attach} title={gettext("Attach to an existing device")} class="mb-6">
        <.form
          for={@attach.form}
          id="attach-form"
          phx-submit="attach"
          class="flex flex-col gap-3 sm:flex-row sm:items-end"
        >
          <Form.input
            field={@attach.form[:device_id]}
            type="select"
            label={gettext("Same machine as")}
            prompt={gettext("Choose a device")}
            options={@attach.options}
            class="flex-1"
            hint={
              case @attach.best do
                {device, score} ->
                  gettext("Best match: %{name} (%{score}%)",
                    name: device.name,
                    score: round(score * 100)
                  )

                nil ->
                  gettext("No close match, pick it manually.")
              end
            }
          />
          <Form.button type="submit" phx-disable-with={gettext("Attaching…")}>
            <.icon name="hero-link-mini" class="size-4" /> {gettext("Attach interfaces")}
          </Form.button>
        </.form>
        <p class="mt-2 text-xs text-muted">
          {gettext(
            "Adds its MAC and IP addresses as new interfaces of that device, instead of creating a new one."
          )}
        </p>
      </.card>

      <.card :if={@discovered} title={gettext("Reported by providers")} class="mb-6" padded={false}>
        <.observation_list observations={@discovered.observations} />
      </.card>

      <.form for={@form} id="device-form" phx-change="validate" phx-submit="save" class="space-y-6">
        <.card title={gettext("General")}>
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Form.input field={@form[:name]} label={gettext("Name")} autofocus={!@device} />
            <Form.input
              field={@form[:id]}
              label={gettext("Identifier")}
              hint={gettext("Used in files and references. Defaults to the name.")}
              disabled={@device != nil}
            />
            <Form.input
              field={@form[:hostname]}
              label={gettext("Hostname")}
              hint={gettext("DNS name. Defaults to the identifier.")}
            />
            <Form.input
              field={@form[:kind]}
              type="select"
              label={gettext("Kind")}
              options={Format.options(Device.kinds())}
            />
            <Form.input
              :if={to_string(@form[:kind].value) == "network"}
              field={@form[:network_role]}
              type="select"
              label={gettext("Role in the network")}
              prompt={gettext("None")}
              options={Format.options(Device.network_roles())}
              hint={gettext("Gateways, switches and access points appear in Routing.")}
            />
            <Form.input
              :if={switch?(@form)}
              field={@form[:port_count]}
              type="number"
              min="1"
              label={gettext("Number of ports")}
              placeholder="8"
            />
            <Form.input
              :if={switch?(@form)}
              field={@form[:poe]}
              type="checkbox"
              label={gettext("Supplies PoE")}
              class="sm:mt-7"
            />
            <Form.input
              :if={network_role_set?(@form)}
              field={@form[:uplink_id]}
              type="select"
              label={gettext("Plugged into")}
              prompt={gettext("Nothing (top of the network)")}
              options={@switch_options}
              hint={gettext("For devices without interface, like unmanaged switches.")}
            />
            <Form.input
              :if={network_role_set?(@form)}
              field={@form[:uplink_port]}
              label={gettext("Port")}
              placeholder="8"
            />
            <Form.input
              field={@form[:tags]}
              label={gettext("Tags")}
              value={list_value(@form[:tags].value)}
              hint={gettext("Comma separated.")}
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

        <.card title={gettext("Metadata")}>
          <:actions>
            <Form.button
              size={:small}
              name="device[metadata_sort][]"
              value="new"
              phx-click={JS.dispatch("change")}
            >
              <.icon name="hero-plus-micro" class="size-4" /> {gettext("Add")}
            </Form.button>
          </:actions>
          <p :if={@form[:metadata].value == []} class="text-sm text-muted">
            {gettext("Brand, model, serial number… add only what you know.")}
          </p>
          <.metadata_datalists labels={@metadata_labels} values_by_label={@metadata_values} />
          <div class="space-y-3">
            <.inputs_for :let={entry_form} field={@form[:metadata]}>
              <div class="flex flex-col gap-2 sm:flex-row sm:items-start">
                <input type="hidden" name="device[metadata_sort][]" value={entry_form.index} />
                <Form.input
                  field={entry_form[:label]}
                  placeholder={gettext("Label")}
                  list="metadata-labels"
                  phx-mounted={Form.blank?(entry_form[:label]) && JS.focus()}
                  class="sm:w-56"
                />
                <Form.input
                  field={entry_form[:value]}
                  placeholder={gettext("Value")}
                  list={metadata_values_list(@metadata_values, entry_form[:label].value)}
                  class="flex-1"
                />
                <Form.button
                  variant={:danger}
                  size={:small}
                  name="device[metadata_drop][]"
                  value={entry_form.index}
                  phx-click={JS.dispatch("change")}
                  class="sm:mt-1.5"
                  title={gettext("Remove")}
                >
                  <.icon name="hero-trash-micro" class="size-4" />
                </Form.button>
              </div>
            </.inputs_for>
          </div>
          <input type="hidden" name="device[metadata_drop][]" />
          <Form.errors errors={Form.visible_errors(@form[:metadata])} />
        </.card>

        <.card title={gettext("Placement")}>
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <Form.input
              field={@form[:placement]}
              value={@placement}
              type="select"
              label={gettext("Where is it?")}
              options={[
                {gettext("In a location"), :location},
                {gettext("Hosted on another device"), :host},
                {gettext("Portable"), :portable},
                {gettext("Unplaced"), :unplaced}
              ]}
            />
            <Form.input
              :if={@placement == "location"}
              field={@form[:location_id]}
              type="select"
              label={gettext("Location")}
              prompt={gettext("Choose a location")}
              options={@location_options}
            />
            <Form.input
              :if={@placement == "host"}
              field={@form[:host_id]}
              type="select"
              label={gettext("Host")}
              prompt={gettext("Choose a host")}
              options={@host_options}
            />
            <Form.input
              :if={@placement == "host"}
              field={@form[:virtualization]}
              type="select"
              label={gettext("Runs as")}
              prompt={gettext("Choose how it runs")}
              options={Format.options(Device.virtualizations())}
            />
            <div class="sm:col-span-2">
              <Form.checkbox_group
                field={@form[:platforms]}
                label={gettext("Hosts guests with")}
                options={Format.options(Device.platforms())}
              />
            </div>
          </div>
        </.card>

        <.card title={gettext("Interfaces")}>
          <:actions>
            <Form.button
              size={:small}
              name="device[interfaces_sort][]"
              value="new"
              phx-click={JS.dispatch("change")}
            >
              <.icon name="hero-plus-micro" class="size-4" /> {gettext("Add interface")}
            </Form.button>
          </:actions>
          <p :if={@form[:interfaces].value == []} class="text-sm text-muted">
            {gettext(
              "No interface yet. Interfaces carry the MAC and IP addresses synchronised to the network services."
            )}
          </p>
          <div class="space-y-4">
            <.inputs_for :let={interface_form} field={@form[:interfaces]}>
              <div class="rounded-lg border border-border p-4">
                <input type="hidden" name="device[interfaces_sort][]" value={interface_form.index} />
                <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
                  <Form.input
                    field={interface_form[:name]}
                    label={gettext("Name")}
                    placeholder="eth0"
                  />
                  <Form.input
                    field={interface_form[:mac]}
                    label={gettext("MAC address")}
                    placeholder="aa:bb:cc:dd:ee:ff"
                  />
                  <Form.input
                    field={interface_form[:assignment]}
                    type="select"
                    label={gettext("Addressing")}
                    options={Enum.map(Interface.assignments(), &{Format.assignment(&1), &1})}
                  />
                  <div>
                    <Form.input
                      field={interface_form[:ip]}
                      label={gettext("IP address")}
                      hint={address_hint(@address_suggestions, interface_form)}
                    />
                    <p
                      :if={@range_suggestions[interface_form.index]}
                      id={"range-suggestion-#{interface_form.index}"}
                      class="mt-1 text-xs text-muted"
                    >
                      {gettext("Next free address of %{range}:",
                        range: @range_suggestions[interface_form.index].range.name
                      )}
                      <button
                        type="button"
                        phx-click={
                          JS.dispatch("belgo:set-value",
                            to: "##{interface_form[:ip].id}",
                            detail: %{value: @range_suggestions[interface_form.index].ip}
                          )
                        }
                        title={gettext("Use this address")}
                        class="font-mono font-medium text-accent underline hover:no-underline"
                      >
                        {@range_suggestions[interface_form.index].ip}
                      </button>
                    </p>
                  </div>
                  <Form.input
                    field={interface_form[:network_id]}
                    type="select"
                    label={gettext("Network")}
                    prompt={gettext("None")}
                    options={@network_options}
                  />
                  <Form.input
                    field={interface_form[:switch_id]}
                    type="select"
                    label={gettext("Switch")}
                    prompt={gettext("None")}
                    options={@switch_options}
                  />
                  <Form.input field={interface_form[:switch_port]} label={gettext("Switch port")} />
                  <Form.input
                    field={interface_form[:dns_names]}
                    label={gettext("DNS names")}
                    value={list_value(interface_form[:dns_names].value)}
                    placeholder="plex, steam"
                    hint={gettext("Comma separated. Short names get the network domain.")}
                    class="sm:col-span-2 lg:col-span-3"
                  />
                  <div class="flex items-end justify-end">
                    <Form.button
                      variant={:danger}
                      size={:small}
                      name="device[interfaces_drop][]"
                      value={interface_form.index}
                      phx-click={JS.dispatch("change")}
                    >
                      <.icon name="hero-trash-micro" class="size-4" /> {gettext("Remove")}
                    </Form.button>
                  </div>
                </div>
              </div>
            </.inputs_for>
          </div>
          <input type="hidden" name="device[interfaces_drop][]" />
          <Form.errors errors={Form.visible_errors(@form[:interfaces])} />
        </.card>

        <div class="flex justify-end gap-2">
          <Form.button navigate={if @device, do: ~p"/devices/#{@device.id}", else: ~p"/devices"}>
            {gettext("Cancel")}
          </Form.button>
          <Form.button type="submit" variant={:primary} phx-disable-with={gettext("Saving…")}>
            {gettext("Save")}
          </Form.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
