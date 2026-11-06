defmodule BelgoWeb.VirtualIps.Status do
  @moduledoc """
  Whether a virtual IP answers: its ping, or its open TCP ports when pings fail (load
  balancer addresses often ignore pings).
  """

  alias Belgo.PortScan.AddressScan
  alias Belgo.Reachability.Status
  alias BelgoWeb.Live.Reachability

  @doc "The status of a virtual IP from the ping results and the port scans."
  @spec build(%{String.t() => term()}, %{String.t() => AddressScan.t()}, String.t()) :: Status.t()
  def build(address_statuses, address_scans, address) do
    open_ports =
      case Map.get(address_scans, address) do
        %AddressScan{state: :done, open_ports: open_ports} -> open_ports
        _unknown -> []
      end

    address_statuses
    |> Reachability.status([address])
    |> Status.with_open_ports(open_ports)
  end
end
