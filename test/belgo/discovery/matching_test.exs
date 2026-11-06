defmodule Belgo.Discovery.MatchingTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Correlation.DiscoveredDevice
  alias Belgo.Discovery.Matching
  alias Belgo.Fixtures

  defp discovered(hostname, description \\ nil) do
    %DiscoveredDevice{id: "mac-x", hostname: hostname, description: description, observations: []}
  end

  test "finds the closest device by name or hostname" do
    devices = Fixtures.snapshot().devices

    assert {%{id: "burns-node"}, score} =
             Matching.best_device(discovered("burns-node-wifi"), devices)

    assert score > 0.8

    assert {%{id: "lisa-laptop"}, _score} =
             Matching.best_device(discovered(nil, "Lisa's Laptop"), devices)
  end

  test "returns nil without a close enough device" do
    assert nil == Matching.best_device(discovered("krusty-burger"), Fixtures.snapshot().devices)
    assert nil == Matching.best_device(discovered(nil), Fixtures.snapshot().devices)
  end
end
