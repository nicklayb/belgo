defmodule Belgo.WakeOnLanTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @environment %{"BELGO_OPNSENSE_API_KEY" => "homer", "BELGO_OPNSENSE_API_SECRET" => "donuts"}

  alias Belgo.Inventory.Device
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

  defp method(tmp_dir, providers) do
    File.write!(Path.join(tmp_dir, "providers.yaml"), "version: 1\nproviders:\n" <> providers)
    WakeOnLan.method(directory: tmp_dir, environment: @environment)
  end

  test "OPNsense sends the packets unless its wake_on_lan option is off", %{tmp_dir: tmp_dir} do
    assert :broadcast == WakeOnLan.method(directory: tmp_dir, environment: @environment)

    assert {:provider, %{module: Belgo.Providers.Opnsense}} =
             method(tmp_dir, "  opnsense:\n    url: https://opnsense.springfield.lan\n")

    assert :disabled ==
             method(
               tmp_dir,
               "  opnsense:\n    url: https://opnsense.springfield.lan\n    wake_on_lan: false\n"
             )

    refute WakeOnLan.enabled?(directory: tmp_dir, environment: @environment)

    # A disabled provider does not count.
    assert :broadcast ==
             method(
               tmp_dir,
               "  opnsense:\n    mode: disabled\n    url: https://opnsense.springfield.lan\n"
             )
  end

  test "waking through OPNsense uses the interface of the device network", %{tmp_dir: tmp_dir} do
    method = method(tmp_dir, "  opnsense:\n    url: https://opnsense.springfield.lan\n")
    lisa_laptop = %Device{id: "lisa-laptop", name: "Lisa's laptop", interfaces: []}
    interface = %Interface{mac: "02:00:00:00:00:30", ip: "10.0.0.30"}

    assert {:ok, :not_watched} = WakeOnLan.wake(lisa_laptop, interface, [], method)

    assert_received {:opnsense_post, "/api/wol/wol/set",
                     %{"wake" => %{"interface" => "lan", "mac" => "02:00:00:00:00:30"}}}

    assert {:error, :disabled} = WakeOnLan.wake(lisa_laptop, interface, [], :disabled)

    assert {:error, :no_address} =
             WakeOnLan.wake(lisa_laptop, %Interface{mac: "02:00:00:00:00:30"}, [], method)
  end
end
