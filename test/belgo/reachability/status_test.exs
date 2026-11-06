defmodule Belgo.Reachability.StatusTest do
  use ExUnit.Case, async: true

  alias Belgo.Reachability.AddressStatus
  alias Belgo.Reachability.Status

  @earlier ~U[2026-11-05 12:00:00Z]
  @later ~U[2026-11-05 12:05:00Z]

  defp address_statuses(results) do
    Map.new(results, fn {address, result, checked_at} ->
      {address, %AddressStatus{address: address, result: result, checked_at: checked_at}}
    end)
  end

  test "a device is up when one of its addresses answers" do
    known =
      address_statuses([{"10.0.0.10", :up, @earlier}, {"10.0.0.11", :down, @later}])

    assert %Status{state: :up, checked_at: @later, results: %{"10.0.0.11" => :down}} =
             Status.build(["10.0.0.11", "10.0.0.10"], known)
  end

  test "pending until an address answers, down when none does" do
    known =
      address_statuses([{"10.0.0.10", :pending, nil}, {"10.0.0.11", :down, @earlier}])

    assert %Status{state: :pending} = Status.build(["10.0.0.10", "10.0.0.11"], known)
    assert %Status{state: :down} = Status.build(["10.0.0.11", "10.0.0.99"], known)
  end

  test "count_states/2 counts the devices in each state" do
    known = address_statuses([{"10.0.0.10", :up, @earlier}, {"10.0.0.11", :down, @earlier}])

    assert %{up: 1, down: 2, unchecked: 1, unknown: 1} ==
             Status.count_states(
               [["10.0.0.10", "10.0.0.11"], ["10.0.0.11"], ["10.0.0.11"], ["10.0.0.99"], []],
               known
             )
  end

  test "unchecked before any ping, unknown without address" do
    assert %Status{state: :unchecked, results: %{}} = Status.build(["10.0.0.99"], %{})
    assert %Status{state: :unknown} = Status.build([], %{})
  end

  test "open TCP ports count as an answer when pings fail" do
    down = %Status{state: :down, addresses: ["10.0.0.110"]}
    assert %Status{state: :up, open_ports: [80, 443]} = Status.with_open_ports(down, [80, 443])
    assert down == Status.with_open_ports(down, [])

    pending = %Status{state: :pending, addresses: ["10.0.0.110"]}
    assert pending == Status.with_open_ports(pending, [80])
  end
end
