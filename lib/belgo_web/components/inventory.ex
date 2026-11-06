defmodule BelgoWeb.Components.Inventory do
  @moduledoc "Components rendering inventory records."

  use Phoenix.Component
  use BelgoWeb, :verified_routes
  use Gettext, backend: BelgoWeb.Gettext

  import BelgoWeb.Components.Core

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Issue
  alias Belgo.Inventory.MetadataLabels
  alias Belgo.PortScan.AddressScan
  alias Belgo.PortScan.Ports
  alias Belgo.Reachability.Status
  alias Belgo.Topology.DeviceNode
  alias BelgoWeb.Format

  @shown_reachability_states [:pending, :up, :down]

  attr(:device, Device, required: true)
  attr(:class, :any, default: nil)

  @doc "Device name with its icon, linking to the device."
  def device_link(assigns) do
    ~H"""
    <.link
      navigate={~p"/devices/#{@device.id}"}
      class={["inline-flex min-w-0 items-center gap-2 font-medium hover:text-accent", @class]}
    >
      <.icon name={Format.device_icon(@device)} class="size-4 shrink-0 text-muted" />
      <span class="truncate">{@device.name}</span>
    </.link>
    """
  end

  attr(:device, Device, required: true)

  @doc "Lightning icon of the switches supplying Power over Ethernet, nothing otherwise."
  def poe_indicator(assigns) do
    ~H"""
    <span
      :if={Device.poe?(@device)}
      data-poe
      role="img"
      title={gettext("PoE")}
      aria-label={gettext("PoE")}
      class="inline-flex shrink-0 items-center text-warning"
    >
      <.icon name="hero-bolt-mini" class="size-4" />
    </span>
    """
  end

  attr(:status, Status, default: nil)
  attr(:clickable, :boolean, default: false, doc: "sends the `ping` event when clicked")
  attr(:id, :string, default: nil)

  @doc """
  Ping indicator of a device: green when it answers, red when it does not, yellow
  while checking, nothing before the first ping or without address. A clickable
  indicator sends the `ping` event (pings again now).
  """
  def reachability_indicator(%{status: %Status{state: state}, clickable: true} = assigns)
      when state in @shown_reachability_states do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-click="ping"
      disabled={@status.state == :pending}
      title={reachability_title(@status, @clickable)}
      aria-label={reachability_title(@status, @clickable)}
      data-state={@status.state}
      class="inline-flex shrink-0 items-center rounded-full p-1.5 hover:bg-surface-muted disabled:cursor-wait"
    >
      <.reachability_dot state={@status.state} />
    </button>
    """
  end

  def reachability_indicator(%{status: %Status{state: state}} = assigns)
      when state in @shown_reachability_states do
    ~H"""
    <span
      id={@id}
      role="img"
      title={reachability_title(@status, @clickable)}
      aria-label={reachability_title(@status, @clickable)}
      data-state={@status.state}
      data-reachability
      class="inline-flex shrink-0 items-center"
    >
      <.reachability_dot state={@status.state} />
    </span>
    """
  end

  def reachability_indicator(assigns), do: ~H""

  attr(:state, :atom, required: true)

  defp reachability_dot(assigns) do
    ~H"""
    <span class={[
      "block size-3 rounded-full ring-2 ring-surface",
      @state == :up && "bg-success",
      @state == :down && "bg-danger",
      @state == :pending && "animate-pulse bg-warning"
    ]} />
    """
  end

  defp reachability_title(%Status{state: :pending}, _clickable?), do: gettext("Pinging…")

  defp reachability_title(%Status{open_ports: [_port | _ports]} = status, clickable?) do
    title =
      gettext("Does not answer ping, but TCP %{ports} accept connections.",
        ports: Enum.join(status.open_ports, ", ")
      )

    if clickable?, do: title <> " " <> gettext("Click to ping again."), else: title
  end

  defp reachability_title(%Status{} = status, clickable?) do
    summary =
      if status.state == :up,
        do: gettext("Answers ping"),
        else: gettext("Does not answer ping")

    details =
      status.results
      |> Enum.sort()
      |> Enum.map_join(", ", fn {address, result} ->
        "#{address}: #{reachability_result(result)}"
      end)

    title =
      gettext("%{summary} (%{details}), checked %{time}.",
        summary: summary,
        details: details,
        time: Format.datetime(status.checked_at)
      )

    if clickable?, do: title <> " " <> gettext("Click to ping again."), else: title
  end

  defp reachability_result(:up), do: gettext("answers")
  defp reachability_result(:down), do: gettext("no answer")
  defp reachability_result(:pending), do: gettext("pinging")
  defp reachability_result({:error, _reason}), do: gettext("ping failed")

  attr(:labels, :list, required: true)
  attr(:values_by_label, :map, required: true)

  @doc """
  Suggestion lists of the metadata inputs: `metadata-labels` for labels, one list of
  values per label (see `metadata_values_list/2`) and one with every value.
  """
  def metadata_datalists(assigns) do
    assigns =
      assign(assigns, :all_values, MetadataLabels.all_values(assigns.values_by_label))

    ~H"""
    <datalist id="metadata-labels">
      <option :for={label <- @labels} value={label} />
    </datalist>
    <datalist
      :for={{label, index} <- Enum.with_index(sorted_labels(@values_by_label))}
      id={values_list_id(index)}
    >
      <option :for={value <- Map.fetch!(@values_by_label, label)} value={value} />
    </datalist>
    <datalist id={values_list_id(:all)}>
      <option :for={value <- @all_values} value={value} />
    </datalist>
    """
  end

  @doc """
  Id of the datalist suggesting values for `label`: values already used with that
  label, or every value when the label is blank or new.
  """
  @spec metadata_values_list(%{String.t() => [String.t()]}, String.t() | nil) :: String.t()
  def metadata_values_list(values_by_label, label) do
    case MetadataLabels.values_for(values_by_label, label) do
      nil ->
        values_list_id(:all)

      _values ->
        indexed = MetadataLabels.canonical(label, Map.keys(values_by_label))

        values_by_label
        |> sorted_labels()
        |> Enum.find_index(&(&1 == indexed))
        |> values_list_id()
    end
  end

  defp sorted_labels(values_by_label), do: Enum.sort(Map.keys(values_by_label))
  defp values_list_id(:all), do: "metadata-values-all"
  defp values_list_id(index), do: "metadata-values-#{index}"

  attr(:platforms, :list, required: true)

  @doc "Badges of the virtualisation platforms of a host."
  def platform_badges(assigns) do
    ~H"""
    <.badge :for={platform <- @platforms} tone={:accent}>{Format.label(platform)}</.badge>
    """
  end

  attr(:nodes, :list, required: true)
  attr(:depth, :integer, default: 0)

  @doc "A device tree: each device followed by its guests, indented."
  def device_tree(assigns) do
    ~H"""
    <ul class={["space-y-1", @depth > 0 && "mt-1 ml-3 border-l border-border pl-3"]}>
      <li :for={%DeviceNode{} = node <- @nodes}>
        <div class="flex flex-wrap items-center gap-2 text-sm">
          <.device_link device={node.device} />
          <span :if={node.device.virtualization} class="text-xs text-muted">
            {Format.label(node.device.virtualization)}
          </span>
          <.platform_badges platforms={node.device.platforms} />
        </div>
        <.device_tree :if={node.guests != []} nodes={node.guests} depth={@depth + 1} />
      </li>
    </ul>
    """
  end

  attr(:issues, :list, required: true)
  attr(:snapshot, :any, default: nil, doc: "when given, issues link to their record")

  @doc "A list of inventory issues."
  def issue_list(assigns) do
    ~H"""
    <ul class="divide-y divide-border">
      <li :for={%Issue{} = issue <- @issues} class="flex items-start gap-3 px-5 py-3 text-sm">
        <.icon
          name={
            if issue.severity == :error,
              do: "hero-exclamation-circle-mini",
              else: "hero-exclamation-triangle-mini"
          }
          class={[
            "mt-0.5 size-5 shrink-0",
            if(issue.severity == :error, do: "text-danger", else: "text-warning")
          ]}
        />
        <div class="min-w-0">
          <.link :if={@snapshot} navigate={issue_path(issue)} class="font-medium hover:text-accent">
            {record_name(@snapshot, issue)}
          </.link>
          <p class="text-muted">{issue.message}</p>
        </div>
      </li>
    </ul>
    """
  end

  defp issue_path(%Issue{collection: :devices, id: id}), do: ~p"/devices/#{id}"
  defp issue_path(%Issue{collection: :locations, id: id}), do: ~p"/locations/#{id}"
  defp issue_path(%Issue{collection: :networks, id: id}), do: ~p"/networks/#{id}/edit"
  defp issue_path(%Issue{collection: :virtual_ips, id: id}), do: ~p"/virtual-ips/#{id}"

  defp record_name(snapshot, %Issue{collection: collection, id: id}) do
    case Belgo.Inventory.Snapshot.fetch(snapshot, collection, id) do
      {:ok, record} -> record.name
      {:error, :not_found} -> id
    end
  end

  attr(:address_scans, :map, required: true)
  attr(:addresses, :list, required: true)

  @doc "The open TCP ports of addresses (`Belgo.PortScan`), with a notice while checking."
  def open_ports(assigns) do
    scans = Enum.map(assigns.addresses, &Map.get(assigns.address_scans, &1))
    done_scans = for %AddressScan{state: :done} = scan <- scans, do: scan

    assigns =
      assign(assigns,
        scanning?: Enum.any?(scans, &(is_nil(&1) or &1.state == :pending)),
        rows:
          for(
            scan <- done_scans,
            port <- scan.open_ports,
            do: %{id: "#{scan.address}-#{port}", address: scan.address, port: port}
          ),
        scanned_at: Enum.max(Enum.map(done_scans, & &1.scanned_at), DateTime, fn -> nil end),
        checked_count: length(Ports.all())
      )

    ~H"""
    <div id="open-ports">
      <p :if={@scanning?} class="flex items-center gap-2 px-5 py-4 text-sm text-muted" data-scanning>
        <.icon name="hero-arrow-path-mini" class="size-4 animate-spin" /> {gettext("Checking ports…")}
      </p>
      <.table :if={@rows != []} id="open-ports-table" rows={@rows}>
        <:col :let={row} label={gettext("Port")}>
          <span class="font-mono">{row.port}</span>
        </:col>
        <:col :let={row} label={gettext("Service")}>{Ports.service(row.port)}</:col>
        <:col :let={row} :if={length(@addresses) > 1} label={gettext("Address")}>
          <span class="font-mono">{row.address}</span>
        </:col>
      </.table>
      <.empty_state
        :if={!@scanning? and @rows == []}
        icon="hero-lock-closed"
        title={gettext("No open port")}
      >
        {gettext("None of the %{count} checked ports accepts connections.", count: @checked_count)}
      </.empty_state>
      <p :if={@scanned_at} class="border-t border-border px-5 py-2 text-xs text-muted">
        {gettext("Checked %{count} common ports on %{date}.",
          count: @checked_count,
          date: Calendar.strftime(@scanned_at, "%Y-%m-%d %H:%M UTC")
        )}
      </p>
    </div>
    """
  end
end
