defmodule Belgo.Sync.PlanTest do
  use ExUnit.Case, async: true

  alias Belgo.Sync.Plan
  alias Belgo.Sync.Plan.Change

  @desired [
    %{name: "moe.springfield.lan", address: "10.0.0.5"},
    %{name: "barney.springfield.lan", address: "10.0.0.6"},
    %{name: "lenny.springfield.lan", address: "10.0.0.7"}
  ]

  @actual [
    %{name: "moe.springfield.lan", address: "10.0.0.99", comment: "kept by the target"},
    %{name: "lenny.springfield.lan", address: "10.0.0.7"},
    %{name: "carl.springfield.lan", address: "10.0.0.8"}
  ]

  defp options, do: [key: & &1.name, comparable: & &1.address]

  test "creates missing entries and updates differing ones" do
    changes = Plan.build(@desired, @actual, options())

    assert [{:create, "barney.springfield.lan"}, {:update, "moe.springfield.lan"}] ==
             Enum.map(changes, &{&1.action, &1.key})

    assert %Change{actual: %{address: "10.0.0.99"}} = Enum.find(changes, &(&1.action == :update))
  end

  test "never plans anything for entries unknown to the inventory" do
    changes = Plan.build(@desired, @actual, options())

    refute Enum.any?(changes, &(&1.key == "carl.springfield.lan"))
    assert Enum.all?(changes, &(&1.action in [:create, :update]))
  end
end
