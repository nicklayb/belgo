defmodule Belgo.Inventory.DeviceSortingTest do
  use ExUnit.Case, async: true

  alias Belgo.Fixtures
  alias Belgo.Inventory.DeviceSorting
  alias Belgo.Inventory.Interface

  @rows [
    {Fixtures.device(id: "ned", name: "Ned PC", interfaces: [%Interface{ip: "10.0.0.100"}]),
     "Leftorium"},
    {Fixtures.device(id: "apu", name: "apu laptop", interfaces: [%Interface{ip: "10.0.0.9"}]),
     "Kwik-E-Mart"},
    {Fixtures.device(id: "barney", name: "Barney phone", interfaces: []), nil}
  ]

  test "sorts by name, case insensitive, in both directions" do
    assert ["apu", "barney", "ned"] == ids(DeviceSorting.sort(@rows, :name, :asc))
    assert ["ned", "barney", "apu"] == ids(DeviceSorting.sort(@rows, :name, :desc))
  end

  test "sorts addresses numerically, devices without one last" do
    assert ["apu", "ned", "barney"] == ids(DeviceSorting.sort(@rows, :address, :asc))
    assert ["ned", "apu", "barney"] == ids(DeviceSorting.sort(@rows, :address, :desc))
  end

  test "sorts by placement, devices without one last" do
    assert ["apu", "ned", "barney"] == ids(DeviceSorting.sort(@rows, :placement, :asc))
  end

  test "clicking the sorted field toggles its direction" do
    assert {:name, :desc} == DeviceSorting.next({:name, :asc}, :name)
    assert {:address, :asc} == DeviceSorting.next({:name, :desc}, :address)
  end

  defp ids(rows), do: Enum.map(rows, fn {device, _placement} -> device.id end)
end
