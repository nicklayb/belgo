defmodule Belgo.Providers.Opnsense.WakeOnLan do
  @moduledoc """
  Wake-on-LAN through the OPNsense `os-wol` plugin. Pure functions only.

  The plugin (`POST /api/wol/wol/set`, `{"wake": {"interface", "mac"}}`) broadcasts
  the magic packet on an interface named by its internal identifier (`lan`,
  `opt1`…), found from the interfaces overview (`/api/interfaces/overview/interfaces_info`
  rows: `identifier`, `addr4` and `ipv4[].ipaddr` as `address/prefix`). Verified in
  the plugin and core sources (master): success is `{"status": <configd output>}`, an
  interface without static IPv4 gives `{"status": "error", "error_msg": …}`, an invalid
  MAC or interface an empty response (`[]`).
  """

  alias Belgo.Network.Cidr
  alias Belgo.Network.IpAddress

  @failed_status "error"

  @doc """
  Finds the internal identifier of the interface whose IPv4 network holds `address`.
  """
  @spec interface_identifier([map()], String.t()) :: {:ok, String.t()} | {:error, term()}
  def interface_identifier(rows, address) do
    with {:ok, parsed} <- parse_address(address) do
      case Enum.find(rows, &interface_holds?(&1, parsed)) do
        nil -> {:error, {:no_interface_for, address}}
        row -> {:ok, row["identifier"]}
      end
    end
  end

  @doc "Body of the wake request."
  @spec body(String.t(), String.t()) :: map()
  def body(interface_identifier, mac),
    do: %{"wake" => %{"interface" => interface_identifier, "mac" => mac}}

  @doc "Interprets the plugin's answer (a decoded JSON map)."
  @spec result(map()) :: :ok | {:error, term()}
  def result(%{"status" => @failed_status} = response),
    do: {:error, {:wake_failed, response["error_msg"]}}

  def result(%{"status" => _status}), do: :ok
  def result(response), do: {:error, {:wake_failed, response}}

  defp parse_address(address) do
    case IpAddress.parse(address) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, {:invalid_address, address}}
    end
  end

  defp interface_holds?(%{"identifier" => identifier} = row, address)
       when is_binary(identifier) and identifier != "" do
    row
    |> interface_networks()
    |> Enum.any?(&Cidr.contains?(&1, address))
  end

  defp interface_holds?(_row, _address), do: false

  defp interface_networks(row) do
    aliases = for %{"ipaddr" => ipaddr} <- List.wrap(row["ipv4"]), do: ipaddr

    for value <- [row["addr4"] | aliases], {:ok, cidr} <- [Cidr.parse(value)], do: cidr
  end
end
