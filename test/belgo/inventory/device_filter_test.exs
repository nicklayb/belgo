defmodule Belgo.Inventory.DeviceFilterTest do
  use ExUnit.Case, async: true

  alias Belgo.Fixtures
  alias Belgo.Inventory.DeviceFilter

  defp ids(params) do
    Fixtures.snapshot().devices
    |> DeviceFilter.apply_filter(DeviceFilter.new(params))
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  test "matches names, addresses and DNS names case insensitively" do
    assert ["smithers"] == ids(%{"query" => "ASSISTANT"})
    assert ["smithers"] == ids(%{"query" => "10.0.0.11"})
    assert ["lisa-laptop"] == ids(%{"query" => "02:00:00:00:00:30"})
  end

  test "filters by several kinds, unknown kinds and blank queries are ignored" do
    assert ["lisa-laptop"] == ids(%{"kinds" => "laptop"})
    assert ["bart-console", "lisa-laptop", "tv-living-room"] == ids(%{"kinds" => "laptop,media"})

    assert length(ids(%{"kinds" => "spaceship", "query" => "  "})) ==
             length(Fixtures.snapshot().devices)
  end

  test "toggle_kind/2 adds then removes a kind" do
    filter = DeviceFilter.toggle_kind(DeviceFilter.new(), :gaming)
    assert [:gaming] == filter.kinds
    assert [] == DeviceFilter.toggle_kind(filter, :gaming).kinds
  end

  test "kind_counts/2 counts the devices matching the other criteria" do
    devices = Fixtures.snapshot().devices
    counts = DeviceFilter.kind_counts(DeviceFilter.new(%{"kinds" => "laptop"}), devices)

    assert 1 == counts.laptop
    assert 2 == counts.media

    assert %{appliance: 1} ==
             DeviceFilter.kind_counts(DeviceFilter.new(%{"query" => "itchy"}), devices)
  end

  test "only set fields go to the query string" do
    assert %{} == DeviceFilter.to_query_params(DeviceFilter.new(%{"query" => "", "kinds" => ""}))

    assert %{"query" => "itchy", "kinds" => "server,media"} ==
             DeviceFilter.to_query_params(
               DeviceFilter.new(%{"query" => "itchy", "kinds" => "server,media"})
             )
  end
end
