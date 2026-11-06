defmodule Belgo.Discovery.SortingTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Correlation.DiscoveredDevice
  alias Belgo.Discovery.Sorting

  defp discovered(id, attributes),
    do: struct!(%DiscoveredDevice{id: id, observations: []}, attributes)

  defp devices do
    [
      discovered("moe", hostname: "moe-pc", ips: ["10.0.0.100"]),
      discovered("apu", hostname: "Apu-Laptop", ips: ["10.0.0.9"]),
      discovered("barney", description: "Barney's phone", macs: ["02:00:00:00:00:99"]),
      discovered("nameless", ips: ["10.0.0.20"])
    ]
  end

  defp ids(devices), do: Enum.map(devices, & &1.id)

  test "sorts by name, case insensitive, nameless last in both directions" do
    assert ~w(apu barney moe nameless) == ids(Sorting.sort(devices(), :device, :asc))
    assert ~w(moe barney apu nameless) == ids(Sorting.sort(devices(), :device, :desc))
  end

  test "sorts addresses numerically, IPs before MAC only devices" do
    assert ~w(apu nameless moe barney) == ids(Sorting.sort(devices(), :address, :asc))
    assert ~w(barney moe nameless apu) == ids(Sorting.sort(devices(), :address, :desc))
  end

  test "clicking a header toggles its direction, another header starts ascending" do
    assert {:device, :desc} == Sorting.next({:device, :asc}, :device)
    assert {:device, :asc} == Sorting.next({:device, :desc}, :device)
    assert {:address, :asc} == Sorting.next({:device, :desc}, :address)
  end

  test "parses known fields only" do
    assert :address == Sorting.parse_field("address")
    assert nil == Sorting.parse_field("bogus")
  end
end
