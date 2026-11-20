defmodule BelgoWeb.Components.Hosting do
  @moduledoc "Live hosting data: where a guest runs right now, and what runs on a host."

  use Phoenix.Component
  use BelgoWeb, :verified_routes
  use Gettext, backend: BelgoWeb.Gettext

  import BelgoWeb.Components.Core

  alias Belgo.Discovery.Workload
  alias Belgo.Discovery.Workloads.LivePlacement
  alias BelgoWeb.Components.Form
  alias BelgoWeb.Format

  @running_statuses ["running", "Running"]

  attr(:placement, LivePlacement, required: true)
  attr(:id, :string, required: true)

  @doc """
  Where a provider sees a guest running, next to the inventory value; when it differs
  and the host is known, a "Set host" button (`set-host` event, `device_id` value)
  moves the device there.
  """
  def live_placement(assigns) do
    ~H"""
    <div id={@id} data-matches={to_string(@placement.matches?)} class="text-sm">
      <span class="inline-flex flex-wrap items-center gap-1.5">
        <.icon
          name={
            if @placement.matches?, do: "hero-check-circle-mini", else: "hero-arrows-right-left-mini"
          }
          class={["size-4", if(@placement.matches?, do: "text-success", else: "text-warning")]}
        />
        <.link
          :if={@placement.host_id}
          navigate={~p"/devices/#{@placement.host_id}"}
          class="font-medium hover:text-accent"
        >
          {@placement.host_name}
        </.link>
        <span :if={!@placement.host_id} class="font-medium">{@placement.host_name}</span>
        <span class="text-xs text-muted">
          {Format.label(@placement.provider)} · {@placement.guest_name}
          <span :if={@placement.status}>· {@placement.status}</span>
        </span>
      </span>
      <Form.button
        :if={!@placement.matches? && @placement.host_id}
        id={"#{@id}-set-host"}
        size={:small}
        class="mt-1"
        phx-click="set-host"
        phx-value-device_id={@placement.device_id}
        title={gettext("Set the device host to where it runs now")}
      >
        {gettext("Set host")}
      </Form.button>
    </div>
    """
  end

  attr(:workload, Workload, required: true)

  @doc "A dot telling whether a workload runs (green) or not (grey)."
  def workload_status(assigns) do
    ~H"""
    <span
      title={@workload.status || gettext("Unknown status")}
      data-status={@workload.status}
      class={[
        "inline-block size-2 shrink-0 rounded-full",
        if(@workload.status in running_statuses(), do: "bg-success", else: "bg-muted")
      ]}
    />
    """
  end

  defp running_statuses, do: @running_statuses
end
