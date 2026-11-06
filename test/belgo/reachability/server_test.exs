defmodule Belgo.Reachability.ServerTest do
  use ExUnit.Case, async: true

  alias Belgo.Reachability
  alias Belgo.Reachability.AddressStatus
  alias Belgo.Reachability.Server

  @moduletag :tmp_dir
  @start ~U[2026-11-05 12:00:00Z]
  @answering_address "10.0.0.10"
  @silent_address "10.0.0.66"

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "config.yaml"), "version: 1\nping:\n  cache_duration: 15m\n")
    {:ok, clock} = Agent.start_link(fn -> @start end)
    test_process = self()
    topic = "reachability-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Belgo.PubSub, topic)

    server =
      start_supervised!(
        {Server,
         directory: tmp_dir,
         name: nil,
         pubsub: Belgo.PubSub,
         topic: topic,
         clock: fn -> Agent.get(clock, & &1) end,
         ping: fn address, _timeout ->
           send(test_process, {:pinged, address})
           Belgo.Fixtures.Pinger.ping(address, 0)
         end}
      )

    {:ok, server: server, clock: clock}
  end

  defp check(context, addresses, options \\ []),
    do: Reachability.check(addresses, Keyword.put(options, :server, context.server))

  defp await_results(count) do
    1..count//1
    |> Enum.flat_map(fn _index -> await_changes() end)
    |> Enum.reject(&AddressStatus.pending?/1)
    |> Map.new(&{&1.address, &1.result})
  end

  defp await_changes do
    assert_receive {:reachability_changed, address_statuses}, 1_000
    address_statuses
  end

  test "pings in the background, then reuses the results for the cache duration", context do
    check(context, [@answering_address, @silent_address])

    assert [%AddressStatus{result: :pending}, %AddressStatus{result: :pending}] =
             await_changes()

    assert_receive {:pinged, @answering_address}, 1_000
    assert_receive {:pinged, @silent_address}, 1_000

    assert %{@answering_address => :up, @silent_address => :down} = await_results(1)

    assert %AddressStatus{result: :up, checked_at: @start} =
             Reachability.address_statuses(context.server)[@answering_address]

    check(context, [@answering_address])
    refute_receive {:pinged, _address}, 50

    Agent.update(context.clock, &DateTime.add(&1, 16, :minute))
    check(context, [@answering_address])
    assert_receive {:pinged, @answering_address}, 1_000
  end

  test "force pings again right away, only the given addresses", context do
    check(context, [@answering_address, @silent_address])
    assert_receive {:pinged, @silent_address}, 1_000
    await_changes()
    await_results(1)

    check(context, [@answering_address], force: true)
    assert [%AddressStatus{result: :pending, checked_at: @start}] = await_changes()
    assert_receive {:pinged, @answering_address}, 1_000
    refute_receive {:pinged, @silent_address}, 50
  end

  test "an address being pinged is not pinged twice", context do
    check(context, [@silent_address])
    check(context, [@silent_address], force: true)

    assert_receive {:pinged, @silent_address}, 1_000
    refute_receive {:pinged, @silent_address}, 50
  end
end
