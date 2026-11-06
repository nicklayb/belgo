defmodule BelgoWeb.Live.PortScans do
  @moduledoc """
  Open ports in a LiveView: `subscribe/1` (connected only) assigns `address_scans`
  and keeps it up to date through `changed/2`, called from the view's
  `{:port_scan_changed, address_scans}` handler. `scan/3` checks on display only
  (connected), reusing recent results.
  """

  alias Belgo.PortScan
  alias Belgo.PortScan.AddressScan
  alias Phoenix.LiveView.Socket

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [connected?: 1]

  @doc "Assigns the known scans and subscribes to their changes (connected only)."
  @spec subscribe(Socket.t()) :: Socket.t()
  def subscribe(socket) do
    if connected?(socket) do
      PortScan.subscribe()
      assign(socket, :address_scans, PortScan.address_scans())
    else
      assign(socket, :address_scans, %{})
    end
  end

  @doc "Checks the addresses without a recent result (connected only); `force: true` checks anyway."
  @spec scan(Socket.t(), [String.t()], Keyword.t()) :: Socket.t()
  def scan(socket, addresses, options \\ []) do
    if connected?(socket), do: PortScan.scan(addresses, options)
    socket
  end

  @doc "Merges changed scans into the `address_scans` assign."
  @spec changed(Socket.t(), [AddressScan.t()]) :: Socket.t()
  def changed(socket, address_scans),
    do:
      update(
        socket,
        :address_scans,
        &Enum.into(address_scans, &1, fn scan -> {scan.address, scan} end)
      )
end
