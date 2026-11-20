defmodule BelgoWeb.Live.Amt do
  @moduledoc """
  Intel AMT in LiveViews (device page and console page): turns the submitted account
  into `Belgo.Amt.Credentials` (the `password` field is filtered from Phoenix logs and
  never assigned), builds the target of the detected AMT and describes errors.
  """

  use Gettext, backend: BelgoWeb.Gettext

  alias Belgo.Amt
  alias Belgo.Amt.Credentials
  alias Belgo.Amt.Detection
  alias Belgo.Amt.Power
  alias Belgo.Amt.Sol
  alias Belgo.Amt.Target
  alias Belgo.Config
  alias Belgo.Inventory.Device

  @read_requests [:console, :status]
  @milliseconds_per_minute 60_000

  @type request :: :console | :status | Power.action()

  @doc "Parses the requested action (`console`, `status` or a power action)."
  @spec parse_request(String.t()) :: {:ok, request()} | :error
  def parse_request(name) do
    case Enum.find(@read_requests, &(Atom.to_string(&1) == name)) do
      nil -> Power.parse_action(name)
      request -> {:ok, request}
    end
  end

  @doc "The AMT detected on the device's addresses (`nil` until a scan confirms one)."
  @spec detection(%{String.t() => term()}, Device.t()) :: Detection.t() | nil
  def detection(address_scans, %Device{} = device),
    do: Amt.detection(address_scans, Device.ip_addresses(device))

  @doc "The target of a detection, with the AMT settings of `config.yaml`."
  @spec target(Detection.t()) :: Target.t()
  def target(%Detection{} = detection), do: Target.new(detection, Config.current().amt)

  @doc "Reads the submitted account: `{:ok, credentials}` or `{:error, message}`."
  @spec credentials(map()) :: {:ok, Credentials.t()} | {:error, String.t()}
  def credentials(%{"password" => password} = params) when is_binary(password) and password != "",
    do: {:ok, Credentials.new(params["username"], password)}

  def credentials(_params), do: {:error, gettext("Type the AMT password.")}

  @doc """
  Whether a disruptive action on a critical device was confirmed (the extra checkbox
  of the form); always `true` otherwise.
  """
  @spec confirmed?(request(), Device.t(), map()) :: boolean()
  def confirmed?(request, %Device{critical: true}, params) when request not in @read_requests,
    do: params["critical_confirmed"] == "true" or not Power.disruptive?(request)

  def confirmed?(_request, _device, _params), do: true

  @doc "Opens the console of the device for the user."
  @spec open_console(String.t(), Device.t(), Detection.t(), Credentials.t()) ::
          {:ok, :opened | :already_open} | {:error, term()}
  def open_console(username, %Device{} = device, %Detection{} = detection, credentials) do
    config = Config.current().amt

    Sol.open(
      username: username,
      device_id: device.id,
      device_name: device.name,
      target: Target.new(detection, config),
      credentials: credentials,
      idle_timeout: config.idle_timeout
    )
  end

  @doc "The label of a request (button and modal title)."
  @spec request_label(request()) :: String.t()
  def request_label(:console), do: gettext("Open the console")
  def request_label(:status), do: gettext("Read status")
  def request_label(:power_on), do: gettext("Power on")
  def request_label(:power_off), do: gettext("Power off")
  def request_label(:reset), do: gettext("Reset")
  def request_label(:power_cycle), do: gettext("Power cycle")

  @doc "The label of a power state."
  @spec power_state_label(Power.state()) :: String.t()
  def power_state_label(:on), do: gettext("On")
  def power_state_label(:off), do: gettext("Off")
  def power_state_label(:sleep), do: gettext("Asleep")
  def power_state_label(:hibernate), do: gettext("Hibernating")
  def power_state_label(:unknown), do: gettext("Unknown")

  @doc "A readable error of an AMT request or console."
  @spec describe_error(term()) :: String.t()
  def describe_error(:unauthorized), do: gettext("AMT refused the account.")

  def describe_error(:ca_file_missing),
    do: gettext("Only the TLS ports of AMT are open: set amt.ca_file in config.yaml.")

  def describe_error(:amtterm_unavailable),
    do: gettext("amtterm is not installed (or BELGO_AMTTERM_PATH is wrong).")

  def describe_error({:request_failed, message}),
    do: gettext("AMT did not answer: %{message}", message: message)

  def describe_error({:return_value, value}),
    do: gettext("AMT refused the action (return value %{value}).", value: value)

  def describe_error({:fault, message}), do: gettext("AMT error: %{message}", message: message)

  def describe_error(reason), do: gettext("AMT error: %{message}", message: inspect(reason))

  @doc "The duration of the console inactivity timeout, in minutes (rounded up)."
  @spec idle_timeout_minutes() :: pos_integer()
  def idle_timeout_minutes do
    div(
      Config.current().amt.idle_timeout + @milliseconds_per_minute - 1,
      @milliseconds_per_minute
    )
  end
end
