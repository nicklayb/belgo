defmodule Belgo.Network.AddressesTest do
  use ExUnit.Case, async: true

  alias Belgo.Network.Cidr
  alias Belgo.Network.IpAddress
  alias Belgo.Network.MacAddress

  describe "IpAddress.parse/1" do
    test "parses IPv4 and IPv6 and rejects garbage" do
      assert {:ok, {10, 0, 0, 42}} = IpAddress.parse(" 10.0.0.42 ")
      assert {:ok, {0xFD00, 0, 0, 0, 0, 0, 0, 1}} = IpAddress.parse("fd00::1")
      assert :error = IpAddress.parse("10.0.0.256")
      assert :error = IpAddress.parse("donut")
      assert :error = IpAddress.parse(nil)
    end
  end

  test "IpAddress integer conversion round trips" do
    for address <- [{10, 0, 0, 42}, {0xFD00, 0, 0, 0, 0, 0, 0, 1}] do
      assert address ==
               address
               |> IpAddress.to_integer()
               |> IpAddress.from_integer(address)
    end
  end

  test "IpAddress.sort_key/1 orders numerically" do
    addresses = ["10.0.0.20", "10.0.0.3", "fd00::1", "10.0.0.100"]

    assert ["10.0.0.3", "10.0.0.20", "10.0.0.100", "fd00::1"] ==
             Enum.sort_by(addresses, &IpAddress.sort_key/1)
  end

  describe "Cidr" do
    test "parses and clears host bits" do
      assert {:ok, cidr} = Cidr.parse("10.0.0.42/24")
      assert "10.0.0.0/24" == Cidr.format(cidr)
      assert 256 == Cidr.size(cidr)
    end

    test "rejects invalid ranges" do
      assert :error = Cidr.parse("10.0.0.0/33")
      assert :error = Cidr.parse("10.0.0.0")
      assert :error = Cidr.parse("springfield/24")
    end

    test "contains?/2 checks the range and the family" do
      {:ok, cidr} = Cidr.parse("10.0.0.0/24")

      assert Cidr.contains?(cidr, {10, 0, 0, 42})
      refute Cidr.contains?(cidr, {10, 0, 1, 42})
      refute Cidr.contains?(cidr, {0, 0, 0, 0, 0, 0, 0, 1})
    end
  end

  test "MacAddress.normalize/1 accepts common notations" do
    for notation <- ["02:00:00:00:07:42", "02-00-00-00-07-42", "0200.0000.0742", "020000000742"] do
      assert {:ok, "02:00:00:00:07:42"} == MacAddress.normalize(String.upcase(notation))
    end

    assert :error = MacAddress.normalize("02:00:00:00:07")
    assert :error = MacAddress.normalize("zz:00:00:00:07:42")
  end
end
