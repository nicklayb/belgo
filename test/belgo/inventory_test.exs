defmodule Belgo.InventoryTest do
  use ExUnit.Case, async: true

  alias Belgo.Accounts.User
  alias Belgo.Fixtures
  alias Belgo.Inventory
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.Storage.YamlDirectory
  alias Belgo.Inventory.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    for collection <- Snapshot.collections() do
      :ok = YamlDirectory.save([path: tmp_dir], Fixtures.snapshot(), collection)
    end

    server = start_supervised!({Store, storage: {YamlDirectory, path: tmp_dir}, name: nil})
    options = [user: %User{username: "homer"}, transaction: [server: server]]

    {:ok, server: server, options: options}
  end

  test "creates a record, persists it and keeps the rest", %{
    server: server,
    options: options,
    tmp_dir: tmp_dir
  } do
    assert {:ok, location} = Inventory.create(:locations, %{"name" => "Moe's Tavern"}, options)
    assert "moes-tavern" == location.id

    assert {:ok, ^location} =
             Snapshot.fetch(Inventory.snapshot(server), :locations, "moes-tavern")

    assert {:ok, from_disk} = YamlDirectory.load(path: tmp_dir)
    assert from_disk == Inventory.snapshot(server)
  end

  test "validates against the rest of the inventory", %{server: server, options: options} do
    params = %{
      "name" => "Flanders PC",
      "interfaces" => [%{"mac" => "02:00:00:00:09:99", "ip" => "10.0.0.10"}]
    }

    assert {:error, :record, changeset, _changes} = Inventory.create(:devices, params, options)
    assert {"IP address 10.0.0.10 is also used by Burns Node", _} = changeset.errors[:interfaces]

    assert {:error, :not_found} =
             Snapshot.fetch(Inventory.snapshot(server), :devices, "flanders-pc")
  end

  test "refuses a taken identifier", %{options: options} do
    assert {:error, :record, changeset, _changes} =
             Inventory.create(:locations, %{"id" => "basement", "name" => "Other"}, options)

    assert {"is already taken", _} = changeset.errors[:id]
  end

  test "updates keep the identifier", %{server: server, options: options} do
    assert {:ok, device} =
             Inventory.update(
               :devices,
               "itchy",
               %{"id" => "scratchy", "name" => "Itchy & Scratchy"},
               options
             )

    assert %{id: "itchy", name: "Itchy & Scratchy"} = device
    assert {:ok, _device} = Snapshot.fetch(Inventory.snapshot(server), :devices, "itchy")
  end

  test "refuses to delete a referenced record", %{server: server, options: options} do
    assert {:error, :record, {:referenced, references}, _changes} =
             Inventory.delete(:devices, "smithers", options)

    assert [{:devices, "itchy", "Itchy"}] == references

    assert {:ok, _itchy} = Inventory.delete(:devices, "itchy", options)
    assert {:ok, _smithers} = Inventory.delete(:devices, "smithers", options)
    assert {:error, :not_found} = Snapshot.fetch(Inventory.snapshot(server), :devices, "smithers")
  end

  test "mutations require a user", %{options: options} do
    assert {:error, :unauthorized} =
             Inventory.create(
               :locations,
               %{"name" => "Kwik-E-Mart"},
               Keyword.delete(options, :user)
             )
  end

  test "reload keeps the current inventory when files are invalid", %{
    server: server,
    tmp_dir: tmp_dir
  } do
    File.write!(YamlDirectory.file_path(tmp_dir, :networks), "version: 1\nnetworks:\n  x: {}\n")

    assert {:error, {:invalid_inventory, [_message]}} = Inventory.reload(server)
    assert Fixtures.snapshot() == Inventory.snapshot(server)
  end

  describe "update_devices/3" do
    test "applies a bulk edit to every device", %{server: server, options: options} do
      assert {:ok, devices} =
               Inventory.update_devices(["smithers", "itchy"], %{"kind" => "gaming"}, options)

      assert ["itchy", "smithers"] == Enum.sort(Enum.map(devices, & &1.id))

      for id <- ["itchy", "smithers"] do
        assert {:ok, %{kind: :gaming}} = Snapshot.fetch(Inventory.snapshot(server), :devices, id)
      end
    end

    test "saves nothing when one device fails", %{server: server, options: options} do
      assert {:error, {:device, "duff-beer"}, :not_found, _changes} =
               Inventory.update_devices(["smithers", "duff-beer"], %{"kind" => "gaming"}, options)

      assert {:ok, %{kind: :server}} =
               Snapshot.fetch(Inventory.snapshot(server), :devices, "smithers")
    end

    test "rejects an empty edit or selection", %{options: options} do
      assert {:error, %Ecto.Changeset{}} = Inventory.update_devices(["smithers"], %{}, options)
      assert {:error, :no_device} = Inventory.update_devices([], %{"kind" => "gaming"}, options)
    end
  end
end
