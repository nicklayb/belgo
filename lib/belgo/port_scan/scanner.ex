defmodule Belgo.PortScan.Scanner do
  @moduledoc """
  Checks which TCP ports of an address accept connections, the gentlest way that
  needs no privilege: a plain TCP handshake closed right away, nothing sent, a
  limited number of connections at a time. Services may log the closed connection.
  """

  alias Belgo.Network.IpAddress

  @maximum_concurrent_connections 8

  @doc "Returns the open ports among `ports`, waiting at most `timeout` milliseconds each."
  @spec open_ports(String.t(), [:inet.port_number()], pos_integer()) :: [:inet.port_number()]
  def open_ports(address, ports, timeout) do
    case IpAddress.parse(address) do
      {:ok, ip} ->
        ports
        |> Task.async_stream(&{&1, open?(ip, &1, timeout)},
          max_concurrency: @maximum_concurrent_connections,
          timeout: :infinity
        )
        |> Enum.flat_map(&open_port/1)
        |> Enum.sort()

      :error ->
        []
    end
  end

  defp open_port({:ok, {port, true = _open?}}), do: [port]
  defp open_port({:ok, {_port, false = _open?}}), do: []

  defp open?(ip, port, timeout) do
    case :gen_tcp.connect(ip, port, [:binary, active: false], timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end
end
