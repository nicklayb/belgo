defmodule Belgo.PortScan do
  @moduledoc """
  Which TCP ports of the devices accept connections (`Belgo.PortScan.Server`, in
  memory, cached for `port_scan.cache_duration`). Only the ports of
  `Belgo.PortScan.Ports` are checked, with plain connections closed right away.
  """

  alias Belgo.PortScan.AddressScan

  @topic "port_scan"

  @doc "PubSub topic receiving `{:port_scan_changed, [AddressScan.t()]}` messages."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the calling process to port scan changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Belgo.PubSub, @topic)

  @doc """
  Checks the addresses in the background, unless a recent result exists (`force:
  true` checks again anyway, except addresses being checked).
  """
  @spec scan([String.t()], Keyword.t()) :: :ok
  def scan(addresses, options \\ []) do
    server = Keyword.get(options, :server, Belgo.PortScan.Server)
    GenServer.cast(server, {:scan, addresses, Keyword.get(options, :force, false)})
  end

  @doc "The known scans, keyed by address."
  @spec address_scans(GenServer.server()) :: %{String.t() => AddressScan.t()}
  def address_scans(server \\ Belgo.PortScan.Server),
    do: GenServer.call(server, :address_scans)
end
