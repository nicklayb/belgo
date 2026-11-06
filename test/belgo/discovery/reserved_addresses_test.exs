defmodule Belgo.Discovery.ReservedAddressesTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Observation
  alias Belgo.Discovery.ReservedAddresses
  alias Belgo.Fixtures
  alias Belgo.Inventory.Interface

  @nelson_reservation %Observation{
    provider: :opnsense,
    source: :kea_reservation,
    kind: :device,
    mac: "02:00:00:00:06:66",
    ip: "10.0.0.66",
    hostname: "nelson-iphone"
  }

  test "a reserved interface on an address reserved for another MAC is a conflict" do
    device =
      Fixtures.device(
        name: "Milhouse",
        interfaces: [%Interface{name: "wlan0", mac: "02:00:00:00:07:77", ip: "10.0.0.66"}]
      )

    assert [
             "Milhouse (wlan0): 10.0.0.66 is already reserved in OPNsense for 02:00:00:00:06:66 (nelson-iphone)"
           ] ==
             ReservedAddresses.conflicts(device, [@nelson_reservation])
  end

  test "the same MAC, another address or a non reserved interface is fine" do
    same_mac =
      Fixtures.device(interfaces: [%Interface{mac: "02:00:00:00:06:66", ip: "10.0.0.66"}])

    other_ip =
      Fixtures.device(interfaces: [%Interface{mac: "02:00:00:00:07:77", ip: "10.0.0.67"}])

    static =
      Fixtures.device(interfaces: [%Interface{assignment: :static, ip: "10.0.0.66"}])

    for device <- [same_mac, other_ip, static] do
      assert [] == ReservedAddresses.conflicts(device, [@nelson_reservation])
    end
  end
end
