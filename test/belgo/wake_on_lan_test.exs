defmodule Belgo.WakeOnLanTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Interface
  alias Belgo.Inventory.Network
  alias Belgo.WakeOnLan
  alias Belgo.WakeOnLan.MagicPacket

  test "the magic packet is 6 × 0xFF then the MAC address 16 times" do
    assert {:ok, packet} = MagicPacket.build("02-00-00-00-00-10")
    assert 102 == byte_size(packet)
    assert <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 2, 0, 0, 0, 0, 0x10, _rest::binary>> = packet
    assert :binary.copy(<<2, 0, 0, 0, 0, 0x10>>, 16) == binary_part(packet, 6, 96)
    assert :error == MagicPacket.build("not a mac")
  end

  test "broadcasts on the local network and on the interface network" do
    networks = [
      %Network{id: "springfield", name: "Springfield", cidr: "10.0.0.0/24"},
      %Network{id: "shelbyville", name: "Shelbyville", cidr: "10.0.5.0/23"}
    ]

    assert ["255.255.255.255", "10.0.0.255"] ==
             WakeOnLan.broadcast_addresses(
               %Interface{mac: "02:00:00:00:00:10", ip: "10.0.0.10"},
               networks
             )

    assert ["255.255.255.255", "10.0.5.255"] ==
             WakeOnLan.broadcast_addresses(
               %Interface{mac: "02:00:00:00:00:10", network_id: "shelbyville"},
               networks
             )

    assert ["255.255.255.255"] ==
             WakeOnLan.broadcast_addresses(%Interface{mac: "02:00:00:00:00:10"}, networks)
  end
end
