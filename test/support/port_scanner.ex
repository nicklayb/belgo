defmodule Belgo.Fixtures.PortScanner do
  @moduledoc "Port scan without network: Burns Node (10.0.0.10) has SSH and Proxmox open."

  @doc "Answers like `Belgo.PortScan.Scanner.open_ports/3`."
  @spec open_ports(String.t(), [:inet.port_number()], pos_integer()) :: [:inet.port_number()]
  def open_ports("10.0.0.10", ports, _timeout), do: Enum.filter(ports, &(&1 in [22, 8006]))
  def open_ports(_address, _ports, _timeout), do: []
end
