defmodule Belgo.Fixtures.PortScanner do
  @moduledoc """
  Port scan without network: Burns Node (10.0.0.10) has SSH, Proxmox and Intel AMT
  (WS-Management and serial over LAN) open.
  """

  @doc "Answers like `Belgo.PortScan.Scanner.open_ports/3`."
  @spec open_ports(String.t(), [:inet.port_number()], pos_integer()) :: [:inet.port_number()]
  def open_ports("10.0.0.10", ports, _timeout),
    do: Enum.filter(ports, &(&1 in [22, 8006, 16_992, 16_994]))

  def open_ports(_address, _ports, _timeout), do: []
end
