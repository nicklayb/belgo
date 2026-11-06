defmodule Belgo.Config.WakeOnLan do
  @moduledoc """
  Settings of the wake-on-LAN watch (milliseconds): once the magic packet is sent,
  the device is pinged every `ping_interval` until it answers or `timeout` elapses.
  """

  @default_ping_interval_milliseconds 5_000
  @default_timeout_milliseconds 60_000

  defstruct ping_interval: @default_ping_interval_milliseconds,
            timeout: @default_timeout_milliseconds

  @type t :: %__MODULE__{ping_interval: pos_integer(), timeout: pos_integer()}
end
