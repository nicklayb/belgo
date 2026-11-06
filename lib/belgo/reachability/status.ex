defmodule Belgo.Reachability.Status do
  @moduledoc """
  Whether a device answers pings: `:pending` while checking, `:up` when at least one of
  its addresses answers, `:down` when none does, `:unknown` without address. `results`
  holds the answer of each address (`:up`, `:down` or `{:error, reason}`).
  """

  @enforce_keys [:device_id, :state, :addresses]
  defstruct [:device_id, :state, :checked_at, addresses: [], results: %{}]

  @type state :: :pending | :up | :down | :unknown
  @type result :: :up | :down | {:error, any()}
  @type t :: %__MODULE__{
          device_id: String.t(),
          state: state(),
          addresses: [String.t()],
          results: %{String.t() => result()},
          checked_at: DateTime.t() | nil
        }

  @doc "Builds the status of a finished check from the answer of each address."
  @spec from_results(String.t(), %{String.t() => result()}, DateTime.t()) :: t()
  def from_results(device_id, results, checked_at) do
    state =
      if Enum.any?(results, fn {_address, result} -> result == :up end), do: :up, else: :down

    %__MODULE__{
      device_id: device_id,
      state: state,
      addresses: Enum.sort(Map.keys(results)),
      results: results,
      checked_at: checked_at
    }
  end

  @doc "Returns `true` when the status answers for these addresses and is younger than `max_age`."
  @spec fresh?(t() | nil, [String.t()], non_neg_integer(), DateTime.t()) :: boolean()
  def fresh?(nil, _addresses, _max_age, _now), do: false
  def fresh?(%__MODULE__{state: :pending}, _addresses, _max_age, _now), do: false
  def fresh?(%__MODULE__{checked_at: nil}, _addresses, _max_age, _now), do: false

  def fresh?(%__MODULE__{} = status, addresses, max_age, now) do
    status.addresses == Enum.sort(addresses) and
      DateTime.diff(now, status.checked_at, :millisecond) < max_age
  end
end
