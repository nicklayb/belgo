defmodule Belgo.Reachability do
  @moduledoc """
  Whether addresses answer pings. Results are kept per address, in memory only
  (`Belgo.Reachability.Server`), and reused for `ping.cache_duration` (`config.yaml`,
  15 minutes by default), so a device and a discovered device sharing an address
  share its result. `Belgo.Reachability.Status.build/2` turns them into a device status.
  """

  alias Belgo.Reachability.AddressStatus
  alias Belgo.Reachability.Server

  @topic "reachability"

  @doc """
  Pings, in the background, the addresses without a recent result. `force: true`
  pings them anyway. Addresses already being pinged are left alone.
  """
  @spec check([String.t()], Keyword.t()) :: :ok
  def check(addresses, options \\ []) do
    GenServer.cast(
      Keyword.get(options, :server, Server),
      {:check, Enum.uniq(addresses), Keyword.get(options, :force, false)}
    )
  end

  @doc "Returns the status of every address checked so far, by address."
  @spec address_statuses(GenServer.server()) :: %{String.t() => AddressStatus.t()}
  def address_statuses(server \\ Server), do: GenServer.call(server, :address_statuses)

  @doc "Merges changed address statuses into those already known."
  @spec merge(%{String.t() => AddressStatus.t()}, [AddressStatus.t()]) ::
          %{String.t() => AddressStatus.t()}
  def merge(address_statuses, changed),
    do: Enum.into(changed, address_statuses, &{&1.address, &1})

  @doc "PubSub topic of the address status changes."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes to `{:reachability_changed, [AddressStatus.t()]}` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Belgo.PubSub, @topic)
end
