defmodule BelgoWeb.Discovery.Live do
  @moduledoc """
  Suggestions from the providers: records to claim or ignore, and divergences with
  the inventory to reconcile.
  """

  @behaviour BelgoWeb.Hooks.Discovery
  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  alias Belgo.Discovery
  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.OutOfDhcpFilter
  alias Belgo.Discovery.Sorting
  alias Belgo.Discovery.State.ProviderStatus
  alias Belgo.Inventory.Interface
  alias Belgo.Inventory.Snapshot
  alias Belgo.Sync.PushReport
  alias BelgoWeb.Format
  alias BelgoWeb.Live.Mutation
  alias BelgoWeb.Live.Reachability

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Discovery"))
     |> assign(:out_of_dhcp_filter, OutOfDhcpFilter.new())
     |> Reachability.subscribe()
     |> assign_inventory()
     |> assign_discovery()}
  end

  # Pings the discovered devices without a recent result (the discovery server also
  # pings them after each pull).
  @impl BelgoWeb.Hooks.Discovery
  def assign_discovery(socket),
    do:
      Reachability.check(
        socket,
        Correlation.discovered_addresses(socket.assigns.discovery.correlation)
      )

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, :out_of_dhcp_filter, OutOfDhcpFilter.new(params))}

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket) do
    assign(socket, :record_names, record_names(socket.assigns.snapshot))
  end

  @impl Phoenix.LiveView
  def handle_info({:reachability_changed, address_statuses}, socket),
    do: {:noreply, Reachability.changed(socket, address_statuses)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("refresh", _params, socket) do
    Discovery.refresh()
    {:noreply, socket}
  end

  def handle_event("refresh-provider", %{"provider" => name}, socket) do
    case Enum.find(socket.assigns.discovery.providers, &(Atom.to_string(&1.key) == name)) do
      %ProviderStatus{key: key} -> Discovery.refresh_provider(key)
      nil -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("filter_out_of_dhcp", params, socket),
    do:
      {:noreply,
       patch_filter(socket, OutOfDhcpFilter.update(socket.assigns.out_of_dhcp_filter, params))}

  def handle_event("sort_out_of_dhcp", %{"field" => name}, socket) do
    case Sorting.parse_field(name) do
      nil ->
        {:noreply, socket}

      field ->
        {:noreply,
         patch_filter(socket, OutOfDhcpFilter.sort_by(socket.assigns.out_of_dhcp_filter, field))}
    end
  end

  def handle_event("ignore", %{"id" => id}, socket) do
    with_discovered_device(socket, id, &Discovery.ignore(&1, Mutation.options(socket)))
  end

  def handle_event("stop-ignoring", %{"id" => id}, socket) do
    with_discovered_device(socket, id, &Discovery.stop_ignoring(&1, Mutation.options(socket)))
  end

  defp with_discovered_device(socket, id, function) do
    with {:ok, discovered} <- Correlation.fetch_device(socket.assigns.discovery.correlation, id),
         {:ok, _entries} <- function.(discovered) do
      {:noreply, socket}
    else
      {:error, :no_mac_address} ->
        {:noreply,
         put_flash(socket, :error, gettext("Only devices with a MAC address can be ignored."))}

      error ->
        {:noreply, put_flash(socket, :error, Mutation.describe_error(error))}
    end
  end

  defp patch_filter(socket, filter) do
    push_patch(socket,
      to: ~p"/discovery?#{OutOfDhcpFilter.to_query_params(filter)}",
      replace: true
    )
  end

  defp provider_options(devices) do
    devices
    |> Enum.flat_map(fn discovered -> Enum.map(discovered.observations, & &1.provider) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{Format.label(&1), Atom.to_string(&1)})
  end

  defp record_names(snapshot) do
    for collection <- [:devices, :networks, :locations, :virtual_ips],
        record <- Map.fetch!(snapshot, collection),
        into: %{} do
      {{collection, record.id}, record.name}
    end
  end

  defp suggested_owner(%{virtual_ip_id: nil, device_id: device_id}), do: {:devices, device_id}
  defp suggested_owner(%{virtual_ip_id: virtual_ip_id}), do: {:virtual_ips, virtual_ip_id}

  defp suggested_interface_name(_snapshot, %{virtual_ip_id: id}) when is_binary(id),
    do: gettext("Virtual IP")

  defp suggested_interface_name(snapshot, dns_name) do
    with {:ok, device} <- Snapshot.fetch(snapshot, :devices, dns_name.device_id),
         %Interface{} = interface <- Enum.at(device.interfaces, dns_name.interface_index) do
      interface.name || interface.ip
    else
      _missing -> ""
    end
  end

  defp divergence_groups(divergences) do
    divergences
    |> Enum.group_by(&{&1.collection, &1.id})
    |> Enum.sort()
  end

  defp record_path({:devices, id}), do: ~p"/devices/#{id}"
  defp record_path({:networks, id}), do: ~p"/networks/#{id}/edit"
  defp record_path({:locations, id}), do: ~p"/locations/#{id}"
  defp record_path({:virtual_ips, id}), do: ~p"/virtual-ips/#{id}"

  @impl Phoenix.LiveView
  def render(assigns) do
    assigns =
      assigns
      |> assign(:correlation, assigns.discovery.correlation)
      |> assign(
        :filtered_out_of_dhcp,
        OutOfDhcpFilter.apply_filter(
          assigns.discovery.correlation.out_of_dhcp_devices,
          assigns.out_of_dhcp_filter
        )
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      navigation_badges={@navigation_badges}
    >
      <.page_header title={gettext("Discovery")}>
        <:subtitle>
          {gettext(
            "What your providers know and Belgo does not. Nothing is saved until you claim it."
          )}
        </:subtitle>
        <:actions>
          <Form.button
            phx-click="refresh"
            disabled={@discovery.providers == [] or Enum.any?(@discovery.providers, & &1.running?)}
          >
            <.icon name="hero-arrow-path-mini" class="size-4" /> {gettext("Refresh")}
          </Form.button>
        </:actions>
      </.page_header>

      <.card :if={@discovery.settings_errors != []} class="mb-6 border-danger/40">
        <p class="mb-2 text-sm font-medium text-danger">{gettext("providers.yaml is invalid")}</p>
        <p :for={message <- @discovery.settings_errors} class="font-mono text-xs">{message}</p>
      </.card>

      <.card :if={@discovery.providers == []}>
        <.empty_state icon="hero-sparkles" title={gettext("No provider configured")}>
          {gettext("Enable providers in providers.yaml, next to the inventory files.")}
        </.empty_state>
      </.card>

      <div :if={@discovery.providers != []} class="space-y-6">
        <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
          <.provider_status :for={provider <- @discovery.providers} provider={provider} />
        </div>

        <.card title={gettext("New networks")} padded={false} collapse_key="discovery-new-networks">
          <:actions>
            <.badge>{length(@correlation.new_networks)}</.badge>
          </:actions>
          <.empty_state
            :if={@correlation.new_networks == []}
            icon="hero-globe-alt"
            title={gettext("No new network")}
          />
          <.table
            :if={@correlation.new_networks != []}
            id="new-networks"
            rows={@correlation.new_networks}
          >
            <:col :let={network} label={gettext("Range")}>
              <p class="font-mono">{network.cidr}</p>
              <p :if={network.description} class="text-xs text-muted">{network.description}</p>
            </:col>
            <:col :let={network} label={gettext("Gateway")} class="hidden sm:table-cell">
              <span class="font-mono">{network.gateway || "—"}</span>
            </:col>
            <:col :let={network} label={gettext("Domain")} class="hidden md:table-cell">
              <span class="font-mono">{network.domain || "—"}</span>
            </:col>
            <:action :let={network}>
              <Form.button
                size={:small}
                variant={:primary}
                navigate={~p"/networks/new?discovered=#{network.id}"}
              >
                {gettext("Claim")}
              </Form.button>
            </:action>
          </.table>
        </.card>

        <.card
          :if={@correlation.new_locations != []}
          title={gettext("New locations")}
          padded={false}
          collapse_key="discovery-new-locations"
        >
          <:actions>
            <.badge>{length(@correlation.new_locations)}</.badge>
          </:actions>
          <.table id="new-locations" rows={@correlation.new_locations}>
            <:col :let={location} label={gettext("Name")}>
              <p class="font-medium">{location.name}</p>
              <p class="text-xs text-muted">{Format.label(location.kind)}</p>
            </:col>
            <:col :let={location} label={gettext("Floor")} class="hidden sm:table-cell">
              {location.parent_name || "—"}
            </:col>
            <:col :let={location} label={gettext("Source")} class="hidden md:table-cell">
              <.source_badges observations={location.observations} />
            </:col>
            <:action :let={location}>
              <Form.button
                size={:small}
                variant={:primary}
                navigate={~p"/locations/new?discovered=#{location.id}"}
              >
                {gettext("Claim")}
              </Form.button>
            </:action>
          </.table>
        </.card>

        <.card
          :if={@correlation.out_of_dhcp_devices != []}
          title={gettext("Out of DHCP")}
          padded={false}
          collapse_key="discovery-out-of-dhcp"
        >
          <:actions>
            <.badge tone={:accent}>{length(@correlation.out_of_dhcp_devices)}</.badge>
          </:actions>
          <p class="border-b border-border px-5 py-3 text-sm text-muted">
            {gettext(
              "Unknown devices whose addresses are outside the DHCP range of their network: static or reserved addresses."
            )}
          </p>
          <.form
            :let={filter_form}
            for={OutOfDhcpFilter.to_query_params(@out_of_dhcp_filter)}
            id="out-of-dhcp-filter"
            phx-change="filter_out_of_dhcp"
            phx-submit="filter_out_of_dhcp"
            class="flex flex-col gap-3 border-b border-border p-4 sm:flex-row"
          >
            <div class="relative flex-1">
              <.icon
                name="hero-magnifying-glass-mini"
                class="pointer-events-none absolute top-2.5 left-3 size-4 text-muted"
              />
              <input
                type="search"
                name={filter_form[:query].name}
                value={filter_form[:query].value}
                placeholder={gettext("Filter by IP, MAC or name…")}
                phx-debounce="150"
                class="block w-full rounded-md border-0 bg-surface py-2 pr-3 pl-9 text-sm ring-1 ring-border ring-inset placeholder:text-muted focus:ring-2 focus:ring-accent focus:outline-none"
              />
            </div>
            <Form.input
              field={filter_form[:provider]}
              type="select"
              prompt={gettext("All providers")}
              options={provider_options(@correlation.out_of_dhcp_devices)}
              class="sm:w-48"
            />
          </.form>
          <.empty_state
            :if={@filtered_out_of_dhcp == []}
            icon="hero-funnel"
            title={gettext("No device matches")}
          />
          <.discovered_devices
            :if={@filtered_out_of_dhcp != []}
            address_statuses={@address_statuses}
            id="out-of-dhcp-devices"
            devices={@filtered_out_of_dhcp}
            sort_event="sort_out_of_dhcp"
            sort={{@out_of_dhcp_filter.sort, @out_of_dhcp_filter.direction}}
          />
        </.card>

        <.card
          title={gettext("Unknown devices")}
          padded={false}
          collapse_key="discovery-unknown-devices"
          collapsed
        >
          <:actions>
            <.badge>{length(@correlation.unknown_devices)}</.badge>
          </:actions>
          <.empty_state
            :if={@correlation.unknown_devices == []}
            icon="hero-server"
            title={gettext("No unknown device")}
          />
          <.discovered_devices
            :if={@correlation.unknown_devices != []}
            address_statuses={@address_statuses}
            id="unknown-devices"
            devices={@correlation.unknown_devices}
          />
        </.card>

        <.card
          :if={@correlation.dns_names != []}
          title={gettext("DNS names")}
          padded={false}
          collapse_key="discovery-dns-names"
        >
          <:actions>
            <.badge tone={:accent}>{length(@correlation.dns_names)}</.badge>
          </:actions>
          <p class="border-b border-border px-5 py-3 text-sm text-muted">
            {gettext(
              "Names resolving to the address of a known device, without belonging to it in Belgo: claim them as DNS names of an interface."
            )}
          </p>
          <.table id="dns-names" rows={@correlation.dns_names}>
            <:col :let={dns_name} label={gettext("Name")}>
              <p class="font-mono">{dns_name.name}</p>
              <p class="font-mono text-xs text-muted">{dns_name.ip}</p>
            </:col>
            <:col :let={dns_name} label={gettext("Suggested interface")}>
              <.link
                navigate={record_path(suggested_owner(dns_name))}
                class="font-medium hover:text-accent"
              >
                {Map.get(@record_names, suggested_owner(dns_name), elem(suggested_owner(dns_name), 1))}
              </.link>
              <p class="text-xs text-muted">
                {suggested_interface_name(@snapshot, dns_name)}
              </p>
            </:col>
            <:col :let={dns_name} label={gettext("Seen in")} class="hidden md:table-cell">
              <.source_badges observations={dns_name.observations} />
            </:col>
            <:action :let={dns_name}>
              <Form.button
                size={:small}
                variant={:primary}
                navigate={~p"/discovery/dns-names/#{dns_name.id}"}
              >
                {gettext("Claim")}
              </Form.button>
            </:action>
          </.table>
        </.card>

        <.card title={gettext("Divergences")} padded={false} collapse_key="discovery-divergences">
          <:actions>
            <.badge tone={if @correlation.divergences == [], do: :neutral, else: :warning}>
              {length(@correlation.divergences)}
            </.badge>
          </:actions>
          <.empty_state
            :if={@correlation.divergences == []}
            icon="hero-check-circle"
            title={gettext("Providers agree with Belgo")}
          />
          <div
            :for={{record, divergences} <- divergence_groups(@correlation.divergences)}
            class="border-b border-border last:border-0"
          >
            <.link
              navigate={record_path(record)}
              class="block px-5 pt-3 text-sm font-medium hover:text-accent"
            >
              {Map.get(@record_names, record, elem(record, 1))}
            </.link>
            <.divergence_list divergences={divergences} />
          </div>
        </.card>

        <.card
          :if={@correlation.ignored_devices != []}
          title={gettext("Ignored")}
          padded={false}
          collapse_key="discovery-ignored"
        >
          <.table id="ignored-devices" rows={@correlation.ignored_devices}>
            <:col :let={device} label={gettext("Device")}>
              <span class="text-muted">{device.hostname || device.description || "—"}</span>
            </:col>
            <:col :let={device} label={gettext("MAC")}>
              <p :for={mac <- device.macs} class="font-mono text-xs">{mac}</p>
            </:col>
            <:action :let={device}>
              <Form.button
                size={:small}
                variant={:ghost}
                phx-click="stop-ignoring"
                phx-value-id={device.id}
              >
                {gettext("Stop ignoring")}
              </Form.button>
            </:action>
          </.table>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr(:id, :string, required: true)
  attr(:devices, :list, required: true)
  attr(:sort_event, :string, default: nil)
  attr(:sort, :any, default: nil)
  attr(:address_statuses, :map, required: true)

  defp discovered_devices(assigns) do
    ~H"""
    <.table id={@id} rows={@devices} sort_event={@sort_event} sort={@sort}>
      <:col :let={device} label={gettext("Device")} sort_field={:device}>
        <p class="flex items-center gap-2 font-medium">
          {device.hostname || device.description || "—"}
          <.reachability_indicator status={Reachability.status(@address_statuses, device.ips)} />
        </p>
        <p :if={device.hostname && device.description} class="text-xs text-muted">
          {device.description}
        </p>
      </:col>
      <:col :let={device} label={gettext("Addresses")} sort_field={:address}>
        <p :for={mac <- device.macs} class="font-mono text-xs">{mac}</p>
        <p :for={ip <- device.ips} class="font-mono text-xs">{ip}</p>
      </:col>
      <:col :let={device} label={gettext("Seen in")} class="hidden md:table-cell">
        <.source_badges observations={device.observations} />
      </:col>
      <:action :let={device}>
        <Form.button
          size={:small}
          variant={:primary}
          navigate={~p"/devices/new?discovered=#{device.id}"}
        >
          {gettext("Claim")}
        </Form.button>
        <Form.button
          :if={length(device.ips) == 1}
          size={:small}
          variant={:ghost}
          navigate={~p"/virtual-ips/new?discovered=#{device.id}"}
          title={gettext("A load balancer or floating address, not a machine")}
        >
          {gettext("Virtual IP")}
        </Form.button>
        <Form.button
          :if={device.macs != []}
          size={:small}
          variant={:ghost}
          phx-click="ignore"
          phx-value-id={device.id}
          title={gettext("Add its MAC addresses to the denylist")}
        >
          {gettext("Ignore")}
        </Form.button>
      </:action>
    </.table>
    """
  end

  defp failed?(%ProviderStatus{running?: true}), do: false
  defp failed?(%ProviderStatus{error: error}) when not is_nil(error), do: true
  defp failed?(%ProviderStatus{report: %{failures: [_failure | _failures]}}), do: true
  defp failed?(%ProviderStatus{}), do: false

  attr(:provider, ProviderStatus, required: true)

  defp provider_status(assigns) do
    ~H"""
    <div class="rounded-xl border border-border bg-surface p-4 shadow-xs">
      <div class="flex items-center justify-between">
        <p class="flex items-center gap-2 font-semibold">
          {@provider.label}
          <.badge>
            {if @provider.mode == :write, do: gettext("Read & write"), else: gettext("Read only")}
          </.badge>
        </p>
        <.badge :if={@provider.running?} tone={:accent}>{gettext("Pulling…")}</.badge>
        <.badge :if={!@provider.running? && @provider.error} tone={:danger}>
          {gettext("Failed")}
        </.badge>
        <.badge :if={!@provider.running? && !@provider.error && @provider.report} tone={:success}>
          {gettext("Up to date")}
        </.badge>
      </div>
      <p class="mt-1 text-xs text-muted">
        {gettext("Last pull: %{time}", time: Format.datetime(@provider.completed_at))}
      </p>
      <p
        :for={{service, reason} <- (@provider.report && @provider.report.failures) || []}
        :if={!@provider.error}
        class="mt-2 font-mono text-xs break-all text-danger"
      >
        {Format.label(service)}: {inspect(reason)}
      </p>
      <p :if={@provider.error} class="mt-2 font-mono text-xs break-all text-danger">
        {inspect(@provider.error)}
      </p>
      <Form.button
        :if={failed?(@provider)}
        size={:small}
        class="mt-3"
        phx-click="refresh-provider"
        phx-value-provider={@provider.key}
        title={gettext("Pull %{provider} again", provider: @provider.label)}
      >
        <.icon name="hero-arrow-path-mini" class="size-4" /> {gettext("Refresh")}
      </Form.button>
      <ul :if={@provider.report} class="mt-2 space-y-0.5 text-sm">
        <li :for={{source, count} <- Enum.sort(@provider.report.counts)} class="flex justify-between">
          <span class="text-muted">{Format.source(source)}</span>
          <span class="tabular-nums">{count}</span>
        </li>
      </ul>
      <div :if={@provider.last_push} class="mt-3 border-t border-border pt-3 text-sm">
        <p class="flex items-center justify-between gap-2">
          <span class="text-muted">
            {gettext("Last push: %{device}", device: @provider.last_push.device_id)}
          </span>
          <.push_badge result={@provider.last_push.result} />
        </p>
        <p class="mt-1 text-xs break-words text-muted">{push_summary(@provider.last_push.result)}</p>
      </div>
    </div>
    """
  end

  attr(:result, :any, required: true)

  defp push_badge(assigns) do
    assigns = assign(assigns, :outcome, push_outcome(assigns.result))

    ~H"""
    <.badge :if={@outcome == :applied} tone={:success}>{gettext("Applied")}</.badge>
    <.badge :if={@outcome == :partial} tone={:danger}>{gettext("Partly failed")}</.badge>
    <.badge :if={@outcome == :failed} tone={:danger}>{gettext("Failed")}</.badge>
    """
  end

  defp push_outcome({:ok, %PushReport{failures: [_ | _]}}), do: :partial
  defp push_outcome({:ok, %PushReport{}}), do: :applied
  defp push_outcome({:error, _reason}), do: :failed

  defp push_summary({:ok, %PushReport{failures: []} = report}), do: PushReport.summary(report)

  defp push_summary({:ok, report}) do
    failures =
      Enum.map_join(report.failures, "; ", fn {service, reason} ->
        "#{service}: #{inspect(reason)}"
      end)

    PushReport.summary(report) <> " — " <> failures
  end

  defp push_summary({:error, reason}), do: inspect(reason)
end
