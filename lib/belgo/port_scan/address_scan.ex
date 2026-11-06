defmodule Belgo.PortScan.AddressScan do
  @moduledoc """
  The open TCP ports of one address: `:pending` while being checked, `:done` with
  `open_ports` (among `checked_ports`) and `scanned_at` once checked.
  """

  @enforce_keys [:address, :state]
  defstruct [:address, :state, :scanned_at, open_ports: [], checked_ports: []]

  @type t :: %__MODULE__{
          address: String.t(),
          state: :pending | :done,
          open_ports: [:inet.port_number()],
          checked_ports: [:inet.port_number()],
          scanned_at: DateTime.t() | nil
        }

  @doc "Whether a finished scan is younger than `cache_duration` milliseconds."
  @spec fresh?(t(), DateTime.t(), non_neg_integer()) :: boolean()
  def fresh?(%__MODULE__{state: :pending}, _now, _cache_duration), do: true

  def fresh?(%__MODULE__{scanned_at: scanned_at}, now, cache_duration),
    do: DateTime.diff(now, scanned_at, :millisecond) < cache_duration
end
