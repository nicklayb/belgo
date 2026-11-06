defmodule Belgo.Inventory.Storage.DuplicateKeysTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Storage.DuplicateKeys

  test "finds identifiers written twice, ignoring nested keys and other collections" do
    content = """
    # Kwik-E-Mart inventory
    devices:
      apu-register:
        name: Apu Register
        interfaces:
          - name: eth0
      'squishee-machine':
        name: Squishee Machine

      apu-register:
        name: Apu Register again
    version: 1
    """

    assert ["apu-register"] == DuplicateKeys.find(content, "devices")
    assert [] == DuplicateKeys.find(content, "locations")
  end

  test "names are not identifiers" do
    content = "devices:\n  homer-pc:\n    name: x\n  marge-pc:\n    name: x\n"

    assert [] == DuplicateKeys.find(content, "devices")
  end
end
