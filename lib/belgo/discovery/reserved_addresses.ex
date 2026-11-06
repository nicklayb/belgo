defmodule Belgo.Discovery.ReservedAddresses do
  @moduledoc """
  DHCP reservations a provider already holds (Kea reservations seen by the last
  discovery) that a device's reserved interface would collide with: same address,
  another MAC address. Pushing such an interface would fail (Kea refuses two
  reservations of one address), so the device form refuses it. Pure functions.
  """

  alias Belgo.Discovery.Observation
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Interface

  @doc "Messages describing each reserved interface whose address is reserved for another MAC."
  @spec conflicts(Device.t(), [Observation.t()]) :: [String.t()]
  def conflicts(%Device{} = device, observations) do
    reservations_by_ip =
      observations
      |> Enum.filter(&(&1.source == :kea_reservation and &1.ip != nil))
      |> Enum.group_by(& &1.ip)

    for %Interface{assignment: :reserved, ip: ip} = interface when ip != nil <- device.interfaces,
        reservation <- Map.get(reservations_by_ip, ip, []),
        reservation.mac != interface.mac do
      "#{Device.interface_label(device, interface)}: #{ip} is already reserved in #{provider_name(reservation)} for #{describe(reservation)}"
    end
  end

  defp provider_name(%Observation{provider: :opnsense}), do: "OPNsense"
  defp provider_name(%Observation{provider: provider}), do: Atom.to_string(provider)

  defp describe(%Observation{mac: mac, hostname: nil}), do: mac
  defp describe(%Observation{mac: mac, hostname: hostname}), do: "#{mac} (#{hostname})"
end
