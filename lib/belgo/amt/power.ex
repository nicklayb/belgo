defmodule Belgo.Amt.Power do
  @moduledoc """
  CIM power states (DMTF DSP1027) read from `CIM_AssociatedPowerManagementService`
  and the actions Belgo asks `CIM_PowerManagementService.RequestPowerStateChange` for
  (the values MeshCommander uses: 2 power on, 8 power off, 10 reset, 5 power cycle).
  """

  @power_state_by_action %{power_on: 2, power_off: 8, reset: 10, power_cycle: 5}
  @state_by_value %{
    2 => :on,
    3 => :sleep,
    4 => :sleep,
    6 => :off,
    7 => :hibernate,
    8 => :off,
    9 => :off,
    12 => :off,
    13 => :off
  }
  @successful_return_value 0

  @type action :: :power_on | :power_off | :reset | :power_cycle
  @type state :: :on | :sleep | :hibernate | :off | :unknown

  @doc "The supported actions, in display order."
  @spec actions() :: [action()]
  def actions, do: [:power_on, :power_off, :reset, :power_cycle]

  @doc "Parses an action name sent by the browser."
  @spec parse_action(String.t()) :: {:ok, action()} | :error
  def parse_action(name) do
    case Enum.find(actions(), &(Atom.to_string(&1) == name)) do
      nil -> :error
      action -> {:ok, action}
    end
  end

  @doc "The CIM power state requested for an action."
  @spec requested_power_state(action()) :: pos_integer()
  def requested_power_state(action), do: Map.fetch!(@power_state_by_action, action)

  @doc "Whether an action stops the running system (off, reset, cycle)."
  @spec disruptive?(action()) :: boolean()
  def disruptive?(action), do: action != :power_on

  @doc "The state of a `PowerState` value (`:unknown` for missing or other values)."
  @spec state(String.t() | integer() | nil) :: state()
  def state(value) when is_integer(value), do: Map.get(@state_by_value, value, :unknown)

  def state(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> state(number)
      _invalid -> :unknown
    end
  end

  def state(nil), do: :unknown

  @doc "Whether `RequestPowerStateChange` succeeded (`ReturnValue` 0)."
  @spec successful?(integer()) :: boolean()
  def successful?(return_value), do: return_value == @successful_return_value
end
