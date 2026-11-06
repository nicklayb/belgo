defmodule Belgo.Inventory.MetadataLabelsTest do
  use ExUnit.Case, async: true

  alias Belgo.Fixtures
  alias Belgo.Inventory.MetadataEntry
  alias Belgo.Inventory.MetadataLabels
  alias Belgo.Inventory.Snapshot

  defp with_metadata(snapshot, id, labels) do
    Snapshot.put(
      snapshot,
      :devices,
      Fixtures.device(
        id: id,
        name: id,
        metadata: Enum.map(labels, &%MetadataEntry{label: &1, value: "Duff"})
      )
    )
  end

  test "used labels come first, most used first, then the unused suggestions" do
    snapshot =
      Fixtures.snapshot()
      |> with_metadata("moe-pc", ["Tavern seat", "brand"])
      |> with_metadata("barney-pc", ["Tavern seat"])

    labels = MetadataLabels.list(snapshot)

    # Brand (Burns Node + moe-pc) and Tavern seat are both used twice: alphabetical.
    assert ["Brand", "Tavern seat", "Serial number" | suggestions] = labels
    assert "Model" in suggestions
    refute "Brand" in suggestions
    assert labels == Enum.uniq_by(labels, &String.downcase/1)
  end

  test "the spelling used by most devices wins" do
    snapshot =
      Fixtures.snapshot()
      |> with_metadata("moe-pc", ["BRAND"])
      |> with_metadata("barney-pc", ["BRAND"])

    assert "BRAND" in MetadataLabels.list(snapshot)
    refute "Brand" in MetadataLabels.list(snapshot)
  end

  test "canonical/2 matches labels case insensitively and keeps new ones" do
    labels = MetadataLabels.list(Fixtures.snapshot())

    assert "Brand" == MetadataLabels.canonical("bRaNd", labels)
    assert "Serial number" == MetadataLabels.canonical(" serial NUMBER ", labels)
    assert "Kwik-E-Mart id" == MetadataLabels.canonical("Kwik-E-Mart id", labels)
  end

  test "values are indexed per label, most used first, case insensitive" do
    snapshot =
      Fixtures.snapshot()
      |> with_metadata("moe-pc", ["brand"])
      |> with_metadata("barney-pc", ["Brand"])

    values = MetadataLabels.values(snapshot)

    assert ["Duff", "Excellent Computers"] == values["Brand"]
    assert ["SN-1895-MB"] == values["Serial number"]
    assert ["Duff", "Excellent Computers"] == MetadataLabels.values_for(values, "BRAND")
    assert nil == MetadataLabels.values_for(values, "Colour")
    assert ["Duff", "Excellent Computers", "SN-1895-MB"] == MetadataLabels.all_values(values)
  end
end
