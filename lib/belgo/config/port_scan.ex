defmodule Belgo.Config.PortScan do
  @moduledoc """
  Settings of the open ports check (milliseconds): a result is reused for
  `cache_duration`, each port connection waits at most `timeout`.
  """

  @default_cache_duration_milliseconds 60 * 60_000
  @default_timeout_milliseconds 1_000

  defstruct cache_duration: @default_cache_duration_milliseconds,
            timeout: @default_timeout_milliseconds

  @type t :: %__MODULE__{cache_duration: non_neg_integer(), timeout: pos_integer()}
end
