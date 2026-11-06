defmodule Belgo.WakeOnLan.Outcome do
  @moduledoc """
  How a wake-on-LAN ended: `:awake` when the device answered a ping, `:timeout` when
  it did not answer within `timeout`. `elapsed` and `timeout` are in milliseconds.
  """

  @enforce_keys [:device_id, :device_name, :result, :elapsed, :timeout]
  defstruct [:device_id, :device_name, :result, :elapsed, :timeout]

  @type t :: %__MODULE__{
          device_id: String.t(),
          device_name: String.t(),
          result: :awake | :timeout,
          elapsed: non_neg_integer(),
          timeout: pos_integer()
        }
end
