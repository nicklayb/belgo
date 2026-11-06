defmodule Belgo.Inventory.IdentifierTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Identifier

  test "slugify/1 builds readable identifiers" do
    assert "moes-tavern" == Identifier.slugify("Moe's Tavern")
    assert "krusty-burger" == Identifier.slugify("  Krusty  Burger! ")
    assert "salle-a-manger" == Identifier.slugify("Salle à manger")
  end
end
