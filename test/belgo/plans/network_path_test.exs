defmodule Belgo.Plans.NetworkPathTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Device
  alias Belgo.Plans.NetworkPath
  alias Belgo.Topology.Routing.Hop
  alias Belgo.Topology.Routing.Link

  defp hop(id, link \\ nil),
    do: %Hop{device: %Device{id: id, name: id}, name: id, link: link}

  defp wired(id), do: hop(id, %Link{device_id: id, source: :inventory})

  defp hops do
    [
      hop("homers-phone", %Link{device_id: "homers-phone", source: :omada, wireless?: true}),
      wired("living-room-ap"),
      wired("basement-switch"),
      wired("attic-switch"),
      hop("gateway"),
      %Hop{name: "Springfield ISP"}
    ]
  end

  test "segments join consecutive placed hops, wireless after the device's link" do
    placed = MapSet.new(~w(homers-phone living-room-ap basement-switch attic-switch gateway))

    assert [
             %{from: "homers-phone", to: "living-room-ap", kind: :wireless},
             %{from: "living-room-ap", to: "basement-switch", kind: :wired},
             %{from: "basement-switch", to: "attic-switch", kind: :wired},
             %{from: "attic-switch", to: "gateway", kind: :wired}
           ] = NetworkPath.segments(hops(), placed)
  end

  test "hops missing from the plan make an indirect segment and are listed" do
    placed = MapSet.new(~w(homers-phone attic-switch))

    assert [%{from: "homers-phone", to: "attic-switch", kind: :indirect}] =
             NetworkPath.segments(hops(), placed)

    assert MapSet.new(~w(living-room-ap basement-switch gateway)) ==
             NetworkPath.unplaced_device_ids(hops(), placed)
  end

  test "a device alone on the plan has no segment" do
    assert [] == NetworkPath.segments(hops(), MapSet.new(["homers-phone"]))
  end
end
