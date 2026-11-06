defmodule Belgo.Discovery.Uplink do
  @moduledoc """
  Where a device is connected right now, as reported by a provider (Omada): the
  switch port or access point, with Wi-Fi details. Computed on each pull, never
  persisted, so roaming between access points does not touch the files.

  `switch_id` is the inventory device of the switch / access point, `nil` when it is
  not claimed yet (then `switch_name` tells what the provider calls it).
  """

  @enforce_keys [:device_id, :provider]
  defstruct [
    :device_id,
    :provider,
    :switch_id,
    :switch_name,
    :port,
    :ssid,
    :locked_to_ap,
    wireless?: false
  ]

  @type t :: %__MODULE__{
          device_id: String.t(),
          provider: atom(),
          switch_id: String.t() | nil,
          switch_name: String.t() | nil,
          port: String.t() | nil,
          ssid: String.t() | nil,
          locked_to_ap: boolean() | nil,
          wireless?: boolean()
        }
end
