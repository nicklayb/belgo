defmodule Belgo.Inventory.Storage.YamlDirectoryTest do
  use ExUnit.Case, async: true

  alias Belgo.Fixtures
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.Storage.YamlDirectory

  @moduletag :tmp_dir

  test "a missing directory is an empty inventory", %{tmp_dir: tmp_dir} do
    assert {:ok, %Snapshot{}} == YamlDirectory.load(path: Path.join(tmp_dir, "nothing"))
  end

  test "saving then loading gives back the same snapshot and the same files", %{tmp_dir: tmp_dir} do
    snapshot = Fixtures.snapshot()
    save_all(tmp_dir, snapshot)
    first_contents = read_all(tmp_dir)

    assert {:ok, ^snapshot} = YamlDirectory.load(path: tmp_dir)

    save_all(tmp_dir, snapshot)
    assert first_contents == read_all(tmp_dir)
  end

  test "files map identifiers to entries", %{tmp_dir: tmp_dir} do
    save_all(tmp_dir, Fixtures.snapshot())

    content = File.read!(YamlDirectory.file_path(tmp_dir, :locations))

    assert content =~ "locations:\n  basement:\n    kind: room\n    name: Basement\n"
    refute content =~ ~r/^\s+id:/m
  end

  test "reports invalid entries with their file and identifier", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "networks.yaml"), """
    version: 1
    networks:
      springfield:
        name: Springfield
        cidr: 10.0.0.0/24
      shelbyville:
        name: Shelbyville
        cidr: not-a-range
    """)

    assert {:error, [message]} = YamlDirectory.load(path: tmp_dir)
    assert message =~ "networks.yaml (shelbyville)"
    assert message =~ "cidr"
  end

  test "rejects duplicate identifiers, invalid identifiers and unknown versions", %{
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, "locations.yaml"), """
    version: 1
    locations:
      kwik-e-mart:
        name: Kwik-E-Mart
      kwik-e-mart:
        name: Kwik-E-Mart again
    """)

    File.write!(Path.join(tmp_dir, "networks.yaml"), """
    version: 1
    networks:
      Power Plant:
        name: Power Plant
        cidr: 10.0.1.0/24
    """)

    File.write!(Path.join(tmp_dir, "devices.yaml"), "version: 2\ndevices: {}\n")

    assert {:error, messages} = YamlDirectory.load(path: tmp_dir)
    assert "locations.yaml: duplicate id kwik-e-mart" in messages
    assert "devices.yaml: expected `version: 1`" in messages
    assert Enum.any?(messages, &(&1 =~ "networks.yaml (Power Plant)"))
  end

  defp save_all(directory, snapshot) do
    for collection <- Snapshot.collections() do
      assert :ok = YamlDirectory.save([path: directory], snapshot, collection)
    end
  end

  defp read_all(directory) do
    for collection <- Snapshot.collections(),
        do: File.read!(YamlDirectory.file_path(directory, collection))
  end
end
