defmodule Belgo.Inventory.SortParamsTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.SortParams

  test "new entries go last, whatever the position of the Add button" do
    assert %{"metadata_sort" => ["0", "1", "new"], "interfaces_sort" => ["0"]} ==
             SortParams.new_last(
               %{"metadata_sort" => ["new", "0", "1"], "interfaces_sort" => ["0"]},
               ["metadata_sort", "interfaces_sort", "missing_sort"]
             )
  end

  test "a device adds the new metadata entry after the existing ones" do
    changeset =
      Device.changeset(%Device{}, %{
        "name" => "Moe PC",
        "metadata_sort" => ["new", "0"],
        "metadata" => %{"0" => %{"label" => "Brand", "value" => "Apple"}}
      })

    assert [%{label: "Brand"}, %{label: nil}] = Ecto.Changeset.get_field(changeset, :metadata)
  end
end
