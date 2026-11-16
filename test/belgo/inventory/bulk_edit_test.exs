defmodule Belgo.Inventory.BulkEditTest do
  use ExUnit.Case, async: true

  alias Belgo.Fixtures
  alias Belgo.Inventory.BulkEdit
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.MetadataEntry

  defp bulk_edit(params) do
    params
    |> BulkEdit.changeset()
    |> Ecto.Changeset.apply_action(:update)
  end

  defp burns_node do
    Fixtures.device(
      id: "burns-node",
      name: "Burns Node",
      kind: :server,
      location_id: "basement",
      metadata: [
        %MetadataEntry{label: "Brand", value: "Excellent Computers"},
        %MetadataEntry{label: "Serial number", value: "SN-1895-MB"}
      ]
    )
  end

  test "metadata entries overwrite the same label, case insensitive, and keep the others" do
    {:ok, edit} =
      bulk_edit(%{
        "metadata" => %{
          "0" => %{"label" => "BRAND", "value" => "Mr. Plow"},
          "1" => %{"label" => "Owner", "value" => "Monty"}
        }
      })

    assert %{"metadata" => metadata, "kind" => "server", "location_id" => "basement"} =
             BulkEdit.device_params(edit, burns_node())

    assert [
             %{"label" => "BRAND", "value" => "Mr. Plow"},
             %{"label" => "Serial number", "value" => "SN-1895-MB"},
             %{"label" => "Owner", "value" => "Monty"}
           ] = metadata
  end

  test "placement replaces the current one, kind drops a network role" do
    {:ok, edit} = bulk_edit(%{"kind" => "gaming", "placement" => "portable"})
    %Device{} = device = burns_node()
    switch = %Device{device | kind: :network, network_role: :switch}

    params = BulkEdit.device_params(edit, switch)

    assert %{"kind" => "gaming", "placement" => "portable"} = params
    refute Map.has_key?(params, "network_role")
  end

  test "sets or clears critical, keeps it when left empty" do
    {:ok, critical} = bulk_edit(%{"critical" => "true"})
    {:ok, not_critical} = bulk_edit(%{"critical" => "false"})
    {:ok, kept} = bulk_edit(%{"critical" => "", "kind" => "media"})
    %Device{} = device = burns_node()

    assert %{"critical" => true} = BulkEdit.device_params(critical, device)

    assert %{"critical" => false} =
             BulkEdit.device_params(not_critical, %{device | critical: true})

    assert %{"critical" => true} = BulkEdit.device_params(kept, %{device | critical: true})
    refute Map.has_key?(BulkEdit.device_params(kept, device), "critical")
  end

  test "requires a change, a location when moving to one, and unique labels" do
    assert {:error, %{errors: [kind: {"choose at least one change", _}]}} = bulk_edit(%{})

    assert {:error, %{errors: [location_id: _]}} = bulk_edit(%{"placement" => "location"})

    assert {:error, %{errors: [metadata: _]}} =
             bulk_edit(%{
               "metadata" => %{
                 "0" => %{"label" => "Brand", "value" => "A"},
                 "1" => %{"label" => "brand", "value" => "B"}
               }
             })
  end
end
