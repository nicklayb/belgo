defmodule BelgoWeb.Components.Amt do
  @moduledoc """
  Intel AMT on the device page: the card (firmware, CVE-2017-5689 warning, power and
  hardware information, console and power buttons) and the account dialog asked
  before every action.
  """

  use Phoenix.Component
  use BelgoWeb, :verified_routes
  use Gettext, backend: BelgoWeb.Gettext

  import BelgoWeb.Components.Core

  alias Belgo.Amt.Detection
  alias Belgo.Amt.Info
  alias Belgo.Amt.Power
  alias Belgo.Amt.Vulnerability
  alias Belgo.Inventory.Device
  alias BelgoWeb.Components.Form
  alias BelgoWeb.Live.Amt, as: LiveAmt

  @bytes_per_gibibyte 1024 * 1024 * 1024

  attr(:device, Device, required: true)
  attr(:detection, Detection, required: true)
  attr(:info, Info, default: nil)
  attr(:busy, :atom, default: nil, doc: "the request being run")
  attr(:console_open?, :boolean, default: false)

  @doc "The AMT card of a device."
  def amt_card(assigns) do
    version =
      (assigns.info && Info.full_firmware_version(assigns.info)) || assigns.detection.version

    assigns =
      assign(assigns,
        vulnerable?: Vulnerability.cve_2017_5689(version) == :vulnerable,
        version: version
      )

    ~H"""
    <.card id="amt" title={gettext("Intel AMT")}>
      <:actions>
        <.badge :if={@info} id="amt-power-state" tone={power_tone(@info.power_state)}>
          {LiveAmt.power_state_label(@info.power_state)}
        </.badge>
      </:actions>
      <div class="space-y-4 text-sm">
        <p class="text-muted">
          {Detection.describe(@detection)} · <span class="font-mono">{@detection.address}</span>
          <span :if={Detection.wsman_tls?(@detection)}> · TLS</span>
        </p>
        <p
          :if={@vulnerable?}
          id="amt-vulnerable"
          class="flex items-start gap-2 rounded-md bg-danger-soft px-3 py-2 text-danger"
        >
          <.icon name="hero-shield-exclamation-mini" class="mt-0.5 size-4 shrink-0" />
          {gettext(
            "Firmware %{version} is vulnerable to CVE-2017-5689 (login without password): update it.",
            version: @version
          )}
        </p>
        <div class="flex flex-wrap gap-2">
          <Form.button
            :if={@console_open?}
            id="amt-console-open"
            size={:small}
            variant={:primary}
            navigate={~p"/devices/#{@device.id}/console"}
          >
            <.icon name="hero-command-line-mini" class="size-4" /> {gettext("Back to the console")}
          </Form.button>
          <Form.button
            :if={!@console_open? and Detection.serial_over_lan?(@detection)}
            id="amt-request-console"
            size={:small}
            phx-click="amt-request"
            phx-value-request="console"
          >
            <.icon name="hero-command-line-mini" class="size-4" /> {LiveAmt.request_label(:console)}
          </Form.button>
          <Form.button
            id="amt-request-status"
            size={:small}
            phx-click="amt-request"
            phx-value-request="status"
            disabled={@busy != nil}
          >
            <.icon name="hero-information-circle-mini" class="size-4" /> {LiveAmt.request_label(
              :status
            )}
          </Form.button>
          <Form.button
            :for={action <- Power.actions()}
            id={"amt-request-#{action}"}
            size={:small}
            variant={if Power.disruptive?(action), do: :danger, else: :secondary}
            phx-click="amt-request"
            phx-value-request={action}
            disabled={@busy != nil}
          >
            <.icon name={action_icon(action)} class="size-4" /> {LiveAmt.request_label(action)}
          </Form.button>
        </div>
        <p :if={@busy} id="amt-busy" class="flex items-center gap-2 text-muted">
          <.icon name="hero-arrow-path-mini" class="size-4 animate-spin" />
          {gettext("Waiting for AMT…")}
        </p>
        <.info_properties :if={@info} info={@info} />
      </div>
    </.card>
    """
  end

  attr(:info, Info, required: true)

  defp info_properties(assigns) do
    ~H"""
    <div id="amt-info">
      <.properties>
        <:item :if={Info.full_firmware_version(@info)} label={gettext("Firmware")}>
          {Info.full_firmware_version(@info)}
        </:item>
        <:item :if={@info.manufacturer || @info.model} label={gettext("Machine")}>
          {Enum.join(Enum.reject([@info.manufacturer, @info.model], &is_nil/1), " ")}
        </:item>
        <:item :if={@info.serial_number} label={gettext("Serial number")}>
          <span class="font-mono">{@info.serial_number}</span>
        </:item>
        <:item :if={@info.bios_version} label={gettext("BIOS")}>
          {Enum.join(
            Enum.reject([@info.bios_vendor, @info.bios_version, @info.bios_release_date], &is_nil/1),
            " · "
          )}
        </:item>
        <:item :if={@info.processors != []} label={gettext("Processor")}>
          {Enum.join(@info.processors, ", ")}
        </:item>
        <:item :if={@info.memory_bytes} label={gettext("Memory")}>
          {gettext("%{size} GiB", size: gibibytes(@info.memory_bytes))}
        </:item>
      </.properties>
    </div>
    """
  end

  attr(:request, :atom, required: true)
  attr(:device, Device, required: true)
  attr(:error, :string, default: nil)
  attr(:form_key, :integer, required: true, doc: "renews the form, so typed passwords go away")

  @doc """
  The dialog asking the AMT account before an action; disruptive power actions on a
  critical device need an extra checkbox.
  """
  def credentials_modal(assigns) do
    assigns =
      assign(assigns,
        form: to_form(%{"username" => Belgo.Amt.Credentials.default_username()}, as: :amt),
        critical_check?:
          assigns.device.critical and assigns.request not in [:console, :status] and
            Power.disruptive?(assigns.request)
      )

    ~H"""
    <div
      id="amt-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      phx-window-keydown="amt-cancel"
      phx-key="Escape"
    >
      <.card
        title={"#{LiveAmt.request_label(@request)} · #{@device.name}"}
        class="w-full max-w-sm shadow-lg"
      >
        <.form
          for={@form}
          id={"amt-form-#{@form_key}"}
          phx-submit="amt-submit"
          autocomplete="off"
          class="space-y-4"
          phx-mounted={Phoenix.LiveView.JS.focus(to: "#amt-password-#{@form_key}")}
        >
          <p :if={@request not in [:console, :status]} class="text-sm">
            {gettext("%{action} %{name}?",
              action: LiveAmt.request_label(@request),
              name: @device.name
            )}
          </p>
          <Form.input field={@form[:username]} label={gettext("AMT account")} />
          <div>
            <label for={"amt-password-#{@form_key}"} class="mb-1 block text-sm font-medium">
              {gettext("Password")}
            </label>
            <input
              type="password"
              id={"amt-password-#{@form_key}"}
              name="amt[password]"
              autocomplete="off"
              class="block w-full rounded-md border-0 bg-surface px-3 py-2 text-sm ring-1 ring-border ring-inset focus:ring-2 focus:ring-accent focus:outline-none"
            />
            <p class="mt-1 text-xs text-muted">
              {gettext("Used for this action only, never stored.")}
            </p>
          </div>
          <label :if={@critical_check?} class="flex items-start gap-2 text-sm text-danger">
            <input
              type="checkbox"
              id="amt-critical-confirmed"
              name="amt[critical_confirmed]"
              value="true"
              class="mt-0.5 size-4"
            />
            {gettext("%{name} is a critical device: I really want to do this.", name: @device.name)}
          </label>
          <p :if={@error} id="amt-error" class="text-sm text-danger">{@error}</p>
          <div class="flex justify-end gap-2">
            <Form.button variant={:ghost} phx-click="amt-cancel">{gettext("Cancel")}</Form.button>
            <Form.button
              type="submit"
              variant={if @request in [:console, :status, :power_on], do: :primary, else: :danger}
            >
              {LiveAmt.request_label(@request)}
            </Form.button>
          </div>
        </.form>
      </.card>
    </div>
    """
  end

  defp power_tone(:on), do: :success
  defp power_tone(:off), do: :neutral
  defp power_tone(_state), do: :warning

  defp action_icon(:power_on), do: "hero-power-mini"
  defp action_icon(:power_off), do: "hero-stop-circle-mini"
  defp action_icon(:reset), do: "hero-arrow-uturn-left-mini"
  defp action_icon(:power_cycle), do: "hero-arrow-path-rounded-square-mini"

  defp gibibytes(bytes) do
    value = bytes / @bytes_per_gibibyte
    if value == trunc(value), do: trunc(value), else: Float.round(value, 1)
  end
end
