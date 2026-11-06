defmodule Belgo.Config.Ping do
  @moduledoc "Settings of the device reachability checks (durations in milliseconds)."

  @default_cache_duration_milliseconds 15 * 60_000
  @default_timeout_milliseconds 2_000

  defstruct cache_duration: @default_cache_duration_milliseconds,
            timeout: @default_timeout_milliseconds

  @type t :: %__MODULE__{cache_duration: non_neg_integer(), timeout: pos_integer()}
end
