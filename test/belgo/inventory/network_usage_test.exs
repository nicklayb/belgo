defmodule Belgo.Inventory.NetworkUsageTest do
  use ExUnit.Case, async: true

  alias Belgo.Fixtures
  alias Belgo.Inventory.AddressRange
  alias Belgo.Inventory.NetworkUsage

  setup do
    snapshot = Fixtures.snapshot()
    [network | _networks] = snapshot.networks

    %{
      snapshot: snapshot,
      network: network,
      holders: NetworkUsage.holders_by_address(snapshot, network)
    }
  end

  test "every address of a range has a row, free ones without holder", %{holders: holders} do
    range = %AddressRange{name: "Routing", start: "10.0.0.1", end: "10.0.0.4", kind: :network}

    assert {:ok, rows} = NetworkUsage.range_rows(range, holders)
    assert ~w(10.0.0.1 10.0.0.2 10.0.0.3 10.0.0.4) == Enum.map(rows, & &1.address)
    # The gateway address is held by the Power Plant device.
    assert [%{name: "Power Plant"}] = Enum.at(rows, 0).holders
    assert [%{name: "Plow King", kind_mismatch?: false}] = Enum.at(rows, 1).holders
    assert [] == Enum.at(rows, 2).holders
    assert 2 == NetworkUsage.used_count(rows)
  end

  test "devices of another kind than the range's are flagged", %{holders: holders} do
    range = %AddressRange{name: "Media", start: "10.0.0.2", end: "10.0.0.2", kind: :media}

    assert {:ok, [%{holders: [%{kind_mismatch?: true}]}]} =
             NetworkUsage.range_rows(range, holders)
  end

  test "huge ranges are not listed", %{holders: holders} do
    range = %AddressRange{name: "Everything", start: "10.0.0.0", end: "10.0.255.255"}
    assert {:too_large, 65_536} = NetworkUsage.range_rows(range, holders)
  end

  test "held addresses outside every range are listed apart", %{
    network: network,
    holders: holders
  } do
    network = %{
      network
      | ranges: [%AddressRange{name: "Routing", start: "10.0.0.1", end: "10.0.0.5"}]
    }

    addresses = Enum.map(NetworkUsage.outside_rows(network, holders), & &1.address)

    refute "10.0.0.2" in addresses
    assert "10.0.0.10" in addresses
  end
end
