defmodule Belgo.Reachability.Status do
  @moduledoc """
  Whether a device answers pings, built from the statuses of its addresses:
  `:up` when at least one address answers, `:pending` while one is being pinged (and
  none answers), `:down` when every pinged address failed, `:unchecked` when none was
  pinged yet, `:unknown` without address. `results` holds each pinged address' result.

  Some addresses never answer pings although they serve (a MetalLB address in L2
  mode, measured on the owner's network): `with_open_ports/2` counts open TCP ports
  as an answer, listed in `open_ports`.
  """

  alias Belgo.Reachability.AddressStatus

  @enforce_keys [:state, :addresses]
  defstruct [:state, :checked_at, addresses: [], results: %{}, open_ports: []]

  @type state :: :pending | :up | :down | :unchecked | :unknown
  @type t :: %__MODULE__{
          state: state(),
          addresses: [String.t()],
          results: %{String.t() => AddressStatus.result()},
          checked_at: DateTime.t() | nil,
          open_ports: [:inet.port_number()]
        }

  @doc "Builds the status of a device's addresses from the known address statuses."
  @spec build([String.t()], %{String.t() => AddressStatus.t()}) :: t()
  def build([], _address_statuses), do: %__MODULE__{state: :unknown, addresses: []}

  def build(addresses, address_statuses) do
    addresses = Enum.sort(Enum.uniq(addresses))

    known =
      for address <- addresses,
          Map.has_key?(address_statuses, address),
          do: address_statuses[address]

    results = Map.new(known, &{&1.address, &1.result})

    %__MODULE__{
      state: state(Map.values(results)),
      addresses: addresses,
      results: results,
      checked_at: last_checked_at(known)
    }
  end

  @doc "Marks the status as answering when TCP ports are open although pings fail."
  @spec with_open_ports(t(), [:inet.port_number()]) :: t()
  def with_open_ports(%__MODULE__{} = status, []), do: status

  def with_open_ports(%__MODULE__{state: state} = status, open_ports)
      when state in [:down, :unchecked],
      do: %{status | state: :up, open_ports: open_ports}

  def with_open_ports(%__MODULE__{} = status, _open_ports), do: status

  @doc "Counts the devices in each state, from the addresses of each device."
  @spec count_states([[String.t()]], %{String.t() => AddressStatus.t()}) ::
          %{state() => non_neg_integer()}
  def count_states(addresses_by_device, address_statuses),
    do: Enum.frequencies_by(addresses_by_device, &build(&1, address_statuses).state)

  defp state([]), do: :unchecked

  defp state(results) do
    cond do
      :up in results -> :up
      :pending in results -> :pending
      true -> :down
    end
  end

  defp last_checked_at(address_statuses) do
    address_statuses
    |> Enum.map(& &1.checked_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end
end
