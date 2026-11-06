defmodule Belgo.Reachability.AddressStatus do
  @moduledoc """
  Last ping of one address: `:pending` while pinging, `:up` when it answered, `:down`
  when it did not, `{:error, reason}` when the ping could not run. `checked_at` is
  the end of the last finished ping (kept while a new one is pending).
  """

  @enforce_keys [:address, :result]
  defstruct [:address, :result, :checked_at]

  @type result :: :pending | :up | :down | {:error, any()}
  @type t :: %__MODULE__{address: String.t(), result: result(), checked_at: DateTime.t() | nil}

  @doc "Returns `true` while the address is being pinged."
  @spec pending?(t() | nil) :: boolean()
  def pending?(%__MODULE__{result: :pending}), do: true
  def pending?(_address_status), do: false

  @doc "Returns `true` when the last finished ping is younger than `max_age` milliseconds."
  @spec fresh?(t() | nil, non_neg_integer(), DateTime.t()) :: boolean()
  def fresh?(%__MODULE__{result: result, checked_at: %DateTime{} = checked_at}, max_age, now)
      when result != :pending,
      do: DateTime.diff(now, checked_at, :millisecond) < max_age

  def fresh?(_address_status, _max_age, _now), do: false
end
