defmodule BelgoWeb.Hosting.Live do
  @moduledoc """
  Virtualisation tree: hosts and the guests running on them, enriched with what the
  providers see running right now (pods, Docker containers, Proxmox guests). Pods and
  containers are nested under their application / Compose project
  (`Belgo.Topology.WorkloadTree`), in collapsed groups; each host lists its first
  entries and expands on demand. Pods can be filtered by application
  (`?app=namespace/app`), which opens the matching groups.
  """

  @behaviour BelgoWeb.Hooks.Discovery
  @behaviour BelgoWeb.Hooks.Inventory

  use BelgoWeb, :live_view

  import BelgoWeb.Components.Hosting

  alias Belgo.Discovery.Workload
  alias Belgo.Discovery.Workloads
  alias Belgo.Topology.Hosting
  alias Belgo.Topology.Hosting.Group
  alias Belgo.Topology.Hosting.Host
  alias Belgo.Topology.WorkloadTree
  alias BelgoWeb.Format
  alias BelgoWeb.Live.SetHost

  @platform_colors %{
    proxmox: "text-proxmox",
    docker: "text-docker",
    kubernetes: "text-kubernetes"
  }
  @platform_icons %{
    proxmox: "hero-server-stack",
    docker: "hero-cube",
    kubernetes: "hero-squares-2x2"
  }
  @collapsed_entry_count 10
  # Kubernetes and Docker hosts list many workloads: one host per row.
  @full_width_platforms [:kubernetes, :docker]
  @app_param "app"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Hosting"))
     |> assign(:app, nil)
     |> assign(:expanded_lists, MapSet.new())
     |> assign_hosting()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    app = Map.get(params, @app_param)
    socket = assign(socket, :app, if(app in [nil, ""], do: nil, else: app))
    {:noreply, assign_hosting(socket)}
  end

  @impl BelgoWeb.Hooks.Inventory
  def assign_inventory(socket), do: assign_hosting(socket)

  @impl BelgoWeb.Hooks.Discovery
  def assign_discovery(socket), do: assign_hosting(socket)

  defp assign_hosting(%{assigns: %{snapshot: snapshot, discovery: discovery}} = socket) do
    workloads = discovery.correlation.workloads

    socket
    |> assign(:workloads, workloads)
    |> assign(:apps, apps(workloads))
    |> assign(:groups, filter_groups(Hosting.groups(snapshot, workloads), socket.assigns.app))
  end

  defp assign_hosting(socket), do: socket

  @impl Phoenix.LiveView
  def handle_event("filter-app", %{"app" => app}, socket) do
    query = if app == "", do: %{}, else: %{@app_param => app}
    {:noreply, push_patch(socket, to: ~p"/hosting?#{query}", replace: true)}
  end

  def handle_event("toggle-workloads", %{"list" => list}, socket) do
    expanded_lists = socket.assigns.expanded_lists

    expanded_lists =
      if MapSet.member?(expanded_lists, list),
        do: MapSet.delete(expanded_lists, list),
        else: MapSet.put(expanded_lists, list)

    {:noreply, assign(socket, :expanded_lists, expanded_lists)}
  end

  def handle_event("set-host", %{"device_id" => device_id}, socket),
    do: {:noreply, SetHost.handle(socket, device_id)}

  @doc "Key of a pod's application in the filter: `namespace/app`."
  @spec app_key(Workload.t()) :: String.t()
  def app_key(%Workload{namespace: namespace, group: group}), do: "#{namespace}/#{group}"

  defp apps(%Workloads{by_host: by_host, unknown_hosts: unknown_hosts}) do
    by_host
    |> Map.values()
    |> Enum.concat(Enum.map(unknown_hosts, & &1.workloads))
    |> List.flatten()
    |> Enum.filter(&(&1.kind == :pod and WorkloadTree.grouped?(&1)))
    |> Enum.map(&app_key/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # With an application selected, Kubernetes nodes keep its pods only and nodes
  # running none of them are left out.
  defp filter_groups(groups, nil), do: groups

  defp filter_groups(groups, app) do
    Enum.flat_map(groups, fn
      %Group{platform: :kubernetes} = group ->
        hosts =
          for %Host{} = host <- group.hosts,
              pods = Enum.filter(host.workloads, &(app_key(&1) == app)),
              pods != [],
              do: %Host{host | workloads: pods}

        if hosts == [], do: [], else: [%Group{group | hosts: hosts}]

      group ->
        [group]
    end)
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
      <.page_header title={gettext("Hosting")}>
        <:subtitle>
          {gettext("Proxmox, Docker and Kubernetes hosts with what runs on them.")}
        </:subtitle>
        <:actions :if={@apps != []}>
          <.form for={%{}} as={:filter} id="app-filter" phx-change="filter-app">
            <select
              name="app"
              id="app-filter-select"
              aria-label={gettext("Application")}
              class="block rounded-md border-0 bg-surface py-1.5 pr-8 pl-3 text-sm ring-1 ring-border ring-inset"
            >
              <option value="">{gettext("All applications")}</option>
              {Phoenix.HTML.Form.options_for_select(@apps, @app)}
            </select>
          </.form>
        </:actions>
      </.page_header>

      <.card :if={@groups == []}>
        <.empty_state icon="hero-rectangle-stack" title={gettext("No host yet")}>
          {gettext("Declare a platform on a device, or host a device on another one.")}
        </.empty_state>
      </.card>

      <div class="space-y-8">
        <section :for={%Group{} = group <- @groups} id={"platform-#{group.platform || "other"}"}>
          <h2 class="mb-3 flex items-center gap-2 text-sm font-semibold tracking-wide text-muted uppercase">
            <.icon
              name={platform_icon(group.platform)}
              class={["size-5", platform_color(group.platform)]}
            />
            {platform_label(group.platform)}
            <.badge>{length(group.hosts)}</.badge>
          </h2>
          <div
            data-layout={if group.platform in full_width_platforms(), do: "rows", else: "grid"}
            class={[
              "grid grid-cols-1 gap-4",
              group.platform not in full_width_platforms() && "lg:grid-cols-2"
            ]}
          >
            <.host_card
              :for={host <- group.hosts}
              host={host}
              platform={group.platform}
              placements={@workloads.placements}
              expanded_lists={@expanded_lists}
              filtered?={@app != nil}
            />
          </div>
        </section>

        <section :if={@workloads.unknown_hosts != []} id="unknown-hosts">
          <h2 class="mb-3 flex items-center gap-2 text-sm font-semibold tracking-wide text-muted uppercase">
            <.icon name="hero-question-mark-circle" class="size-5 text-warning" />
            {gettext("Hosts unknown to Belgo")}
          </h2>
          <.card padded={false}>
            <ul class="divide-y divide-border text-sm">
              <li
                :for={unknown <- @workloads.unknown_hosts}
                class="flex flex-wrap items-center gap-2 px-5 py-2.5"
              >
                <span class="font-mono">{unknown.name}</span>
                <.badge>{Format.label(unknown.provider)}</.badge>
                <span class="ml-auto text-xs text-muted">
                  {workload_summary(unknown.workloads)}
                </span>
              </li>
            </ul>
          </.card>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr(:host, Host, required: true)
  attr(:platform, :atom, required: true)
  attr(:placements, :map, required: true)
  attr(:expanded_lists, MapSet, required: true)
  attr(:filtered?, :boolean, required: true)

  defp host_card(assigns) do
    ~H"""
    <.card id={"host-#{@platform || "other"}-#{@host.device.id}"}>
      <div class="flex flex-wrap items-center gap-2">
        <.device_link device={@host.device} class="text-base" />
        <.platform_badges platforms={@host.device.platforms} />
        <span class="ml-auto text-xs text-muted">
          {ngettext("1 guest", "%{count} guests", length(@host.guests))}
        </span>
      </div>
      <p :if={@host.hosts != []} class="mt-0.5 text-xs text-muted">
        {gettext("%{runs_as} on %{hosts}",
          runs_as: Format.label(@host.device.virtualization),
          hosts: Enum.map_join(@host.hosts, " › ", & &1.name)
        )}
      </p>
      <ul :if={@host.guests != []} class="mt-3 space-y-1">
        <li :for={guest <- @host.guests} class="text-sm">
          <span class="flex flex-wrap items-center gap-2">
            <.device_link device={guest} />
            <span class="text-xs text-muted">{Format.label(guest.virtualization)}</span>
            <.platform_badges platforms={guest.platforms} />
          </span>
          <.live_placement
            :if={@placements[guest.id] && !@placements[guest.id].matches?}
            id={"placement-#{@host.device.id}-#{guest.id}"}
            placement={@placements[guest.id]}
          />
        </li>
      </ul>
      <p :if={@host.guests == [] && @host.workloads == []} class="mt-3 text-sm text-muted">
        {gettext("Nothing runs here yet.")}
      </p>
      <.workload_tree
        :if={@platform in full_width_platforms() && @host.workloads != []}
        id={"#{workload_noun(@platform)}-#{@host.device.id}"}
        platform={@platform}
        workloads={@host.workloads}
        expanded?={MapSet.member?(@expanded_lists, "#{workload_noun(@platform)}-#{@host.device.id}")}
        filtered?={@filtered?}
      />
      <.live_guests
        :if={@platform == :proxmox}
        host={@host}
        guests={running_elsewhere_in_belgo(@host)}
      />
    </.card>
    """
  end

  attr(:id, :string, required: true)
  attr(:platform, :atom, required: true)
  attr(:workloads, :list, required: true)
  attr(:expanded?, :boolean, required: true)
  attr(:filtered?, :boolean, required: true)

  # Pods or containers of a host, nested under their groups; the first entries
  # (groups or ungrouped workloads) are shown until expanded.
  defp workload_tree(assigns) do
    entries = WorkloadTree.build(assigns.workloads)

    assigns =
      assigns
      |> assign(:entry_count, length(entries))
      |> assign(
        :entries,
        if(assigns.expanded?, do: entries, else: Enum.take(entries, collapsed_count()))
      )

    ~H"""
    <div id={@id} class="mt-3 border-t border-border pt-3">
      <p class="mb-1.5 text-xs font-medium text-muted">
        {workload_count_label(@platform, @workloads)}
      </p>
      <ul class="space-y-1">
        <li :for={entry <- @entries} class="text-sm">
          <.workload_group
            :if={match?(%WorkloadTree.Group{}, entry)}
            id={group_id(@id, entry, @filtered?)}
            group={entry}
            platform={@platform}
            open?={@filtered?}
          />
          <.workload_row :if={match?(%Workload{}, entry)} workload={entry} />
        </li>
      </ul>
      <Form.button
        :if={@entry_count > collapsed_count()}
        id={"toggle-#{@id}"}
        size={:small}
        variant={:ghost}
        class="mt-1.5"
        phx-click="toggle-workloads"
        phx-value-list={@id}
      >
        {if @expanded?,
          do: gettext("Show fewer"),
          else: ngettext("Show 1 more", "Show %{count} more", @entry_count - collapsed_count())}
      </Form.button>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:group, WorkloadTree.Group, required: true)
  attr(:platform, :atom, required: true)
  attr(:open?, :boolean, required: true)

  defp workload_group(assigns) do
    ~H"""
    <details
      id={@id}
      open={@open?}
      phx-mounted={JS.ignore_attributes("open")}
      data-workload-group={@group.name}
      class="group/workloads"
    >
      <summary class="flex min-w-0 cursor-pointer list-none items-center gap-2 rounded-md select-none hover:bg-surface-muted [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right-mini"
          class="size-4 shrink-0 text-muted transition-transform group-open/workloads:rotate-90"
        />
        <span class="truncate font-medium">{@group.name}</span>
        <.badge tone={@platform}>{length(@group.workloads)}</.badge>
        <span :if={@group.namespace} class="ml-auto text-xs text-muted">{@group.namespace}</span>
      </summary>
      <ul class="mt-1 ml-2 space-y-1 border-l border-border pl-4">
        <li :for={workload <- @group.workloads}>
          <.workload_row workload={workload} />
        </li>
      </ul>
    </details>
    """
  end

  attr(:workload, Workload, required: true)

  defp workload_row(%{workload: %Workload{kind: :pod}} = assigns) do
    ~H"""
    <span class="flex min-w-0 items-center gap-2 text-sm" data-pod={@workload.name}>
      <.workload_status workload={@workload} />
      <span class="truncate font-mono text-xs">{@workload.name}</span>
      <span :if={!WorkloadTree.grouped?(@workload)} class="ml-auto text-xs text-muted">
        {@workload.namespace}
      </span>
    </span>
    """
  end

  defp workload_row(assigns) do
    ~H"""
    <span class="flex min-w-0 items-center gap-2 text-sm" data-container={@workload.name}>
      <.workload_status workload={@workload} />
      <span class="truncate font-mono text-xs">{@workload.name}</span>
      <span class="ml-auto truncate text-xs text-muted">{@workload.image}</span>
    </span>
    """
  end

  attr(:host, Host, required: true)
  attr(:guests, :list, required: true)

  # Guests seen running on this node that the inventory does not place here: unknown
  # to Belgo, or hosted elsewhere in Belgo.
  defp live_guests(assigns) do
    ~H"""
    <div
      :if={@guests != []}
      id={"live-guests-#{@host.device.id}"}
      class="mt-3 border-t border-border pt-3"
    >
      <p class="mb-1.5 text-xs font-medium text-muted">{gettext("Also running here")}</p>
      <ul class="space-y-1">
        <li
          :for={guest <- @guests}
          class="flex flex-wrap items-center gap-2 text-sm"
          data-live-guest={guest.name}
        >
          <.workload_status workload={guest} />
          <.link
            :if={guest.device_id}
            navigate={~p"/devices/#{guest.device_id}"}
            class="font-medium hover:text-accent"
          >
            {guest.name}
          </.link>
          <span :if={!guest.device_id} class="font-medium">{guest.name}</span>
          <span class="text-xs text-muted">{Format.label(guest.kind)}</span>
          <.badge :if={!guest.device_id} tone={:warning}>{gettext("Not in Belgo")}</.badge>
          <.badge :if={guest.device_id} tone={:warning}>
            {gettext("Hosted elsewhere in Belgo")}
          </.badge>
          <Form.button
            :if={guest.device_id}
            id={"set-host-#{@host.device.id}-#{guest.device_id}"}
            size={:small}
            phx-click="set-host"
            phx-value-device_id={guest.device_id}
            title={gettext("Set the device host to where it runs now")}
          >
            {gettext("Set host")}
          </Form.button>
        </li>
      </ul>
    </div>
    """
  end

  defp running_elsewhere_in_belgo(%Host{device: device, guests: guests, workloads: workloads}) do
    guest_ids = MapSet.new(guests, & &1.id)

    Enum.reject(workloads, fn workload ->
      workload.device_id != nil and
        (MapSet.member?(guest_ids, workload.device_id) or workload.device_id == device.id)
    end)
  end

  defp workload_summary(workloads) do
    workloads
    |> Enum.frequencies_by(& &1.kind)
    |> Enum.sort()
    |> Enum.map_join(", ", fn {kind, count} -> "#{count} × #{Format.label(kind)}" end)
  end

  defp collapsed_count, do: @collapsed_entry_count

  defp full_width_platforms, do: @full_width_platforms

  defp workload_noun(:kubernetes), do: "pods"
  defp workload_noun(_platform), do: "containers"

  defp workload_count_label(:kubernetes, pods),
    do: ngettext("1 pod", "%{count} pods", length(pods))

  defp workload_count_label(_platform, containers),
    do: ngettext("1 running container", "%{count} running containers", length(containers))

  # Filtering renders groups open: a distinct id keeps the browser's `open` state
  # (ignored across patches) from hiding the filtered application.
  defp group_id(list_id, %WorkloadTree.Group{name: name, namespace: namespace}, filtered?) do
    [list_id, "group", namespace, name, filtered? && "filtered"]
    |> Enum.filter(& &1)
    |> Enum.join("-")
  end

  defp platform_label(nil), do: gettext("Other hosts")
  defp platform_label(platform), do: Format.label(platform)

  # The platform's colour (same as its badges), the accent for "Other".
  defp platform_color(platform), do: Map.get(@platform_colors, platform, "text-accent")

  defp platform_icon(platform), do: Map.get(@platform_icons, platform, "hero-rectangle-stack")
end
