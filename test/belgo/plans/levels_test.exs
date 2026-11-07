defmodule Belgo.Plans.LevelsTest do
  use ExUnit.Case, async: true

  alias Belgo.Plans.Level
  alias Belgo.Plans.Levels
  alias Belgo.Plans.Plan

  @plan %Plan{
    id: "evergreen-terrace",
    name: "742 Evergreen Terrace",
    level_height: 270,
    wall_height: 250
  }

  test "a level without its own heights uses the home's" do
    level = %Level{id: "ground-floor", name: "Ground floor"}

    assert 270 == Levels.height(level, @plan)
    assert 250 == Levels.wall_height(level, @plan)
    assert 300 == Levels.height(%{level | height: 300}, @plan)
    assert 280 == Levels.wall_height(%{level | wall_height: 280}, @plan)
  end

  test "a level stands its offset times its base level's own height above it" do
    levels = [
      %Level{id: "basement", name: "Basement", offset: 0.0, height: 220},
      %Level{id: "ground-floor", name: "Ground floor", base_id: "basement", offset: 1.0},
      %Level{id: "attic", name: "Attic", base_id: "ground-floor", offset: 1.0, height: 180},
      %Level{id: "garage", name: "Garage", base_id: "basement", offset: 0.5}
    ]

    assert {:ok,
            %{"basement" => 0.0, "ground-floor" => 220.0, "attic" => 490.0, "garage" => 110.0}} =
             Levels.elevations(levels, 270)
  end
end
