defmodule BelgoWeb.Live.Reachability do
  @moduledoc """
  Ping results in a LiveView: `subscribe/1` (connected only) assigns
  `address_statuses` and keeps it up to date through `changed/2`, called from the
  view's `{:reachability_changed, address_statuses}` handler. `check/3` pings on
  display only (connected), reusing recent results.
  """

  alias Belgo.Reachability
  alias Belgo.Reachability.AddressStatus
  alias Belgo.Reachability.Status
  alias Phoenix.LiveView.Socket

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  @doc "Assigns the known address statuses and subscribes to their changes (connected only)."
  @spec subscribe(Socket.t()) :: Socket.t()
  def subscribe(socket) do
    if connected?(socket) do
      Reachability.subscribe()
      assign(socket, :address_statuses, Reachability.address_statuses())
    else
      assign(socket, :address_statuses, %{})
    end
  end

  @doc "Pings the addresses without a recent result (connected only); `force: true` pings anyway."
  @spec check(Socket.t(), [String.t()], Keyword.t()) :: Socket.t()
  def check(socket, addresses, options \\ []) do
    if connected?(socket), do: Reachability.check(addresses, options)
    socket
  end

  @doc "Merges changed address statuses into the `address_statuses` assign."
  @spec changed(Socket.t(), [AddressStatus.t()]) :: Socket.t()
  def changed(socket, address_statuses),
    do: update(socket, :address_statuses, &Reachability.merge(&1, address_statuses))

  @doc "Status of a set of addresses according to the `address_statuses` assign."
  @spec status(%{String.t() => AddressStatus.t()}, [String.t()]) :: Status.t()
  def status(address_statuses, addresses), do: Status.build(addresses, address_statuses)
end
