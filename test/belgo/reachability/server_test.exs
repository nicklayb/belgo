defmodule Belgo.Reachability.ServerTest do
  use ExUnit.Case, async: true

  alias Belgo.Fixtures
  alias Belgo.Reachability
  alias Belgo.Reachability.Server
  alias Belgo.Reachability.Status

  @moduletag :tmp_dir
  @start ~U[2026-11-05 12:00:00Z]

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "config.yaml"), "version: 1\nping:\n  cache_duration: 15m\n")
    {:ok, clock} = Agent.start_link(fn -> @start end)
    test_process = self()

    server =
      start_supervised!(
        {Server,
         directory: tmp_dir,
         name: nil,
         pubsub: Belgo.PubSub,
         clock: fn -> Agent.get(clock, & &1) end,
         ping: fn address, _timeout ->
           send(test_process, {:pinged, address})
           Fixtures.Pinger.ping(address, 0)
         end}
      )

    device_id = "burns-node-#{System.unique_integer([:positive])}"
    Reachability.subscribe(device_id)
    device = Fixtures.device(id: device_id, interfaces: [Fixtures.interface(ip: "10.0.0.10")])

    {:ok, server: server, clock: clock, device: device}
  end

  defp check(context, options \\ []),
    do: Reachability.check(context.device, Keyword.put(options, :server, context.server))

  defp await_result do
    assert_receive {:reachability_changed, %Status{state: state} = status}
                   when state != :pending,
                   1_000

    status
  end

  test "pings in the background, then reuses the result for the cache duration", context do
    assert %Status{state: :pending} = check(context)
    assert_receive {:pinged, "10.0.0.10"}

    assert %Status{state: :up, results: %{"10.0.0.10" => :up}, checked_at: @start} =
             await_result()

    assert %Status{state: :up} = check(context)
    refute_receive {:pinged, _address}, 50

    Agent.update(context.clock, &DateTime.add(&1, 16, :minute))
    assert %Status{state: :pending} = check(context)
    assert_receive {:pinged, "10.0.0.10"}
  end

  test "force pings again right away", context do
    check(context)
    await_result()

    assert %Status{state: :pending} = check(context, force: true)
    assert_receive {:pinged, "10.0.0.10"}
    assert %Status{state: :up} = await_result()
  end

  test "new addresses are pinged even with a recent result", context do
    check(context)
    await_result()

    device = %{context.device | interfaces: [Fixtures.interface(ip: "10.0.0.66")]}
    assert %Status{state: :pending} = Reachability.check(device, server: context.server)
    assert %Status{state: :down, results: %{"10.0.0.66" => :down}} = await_result()
  end

  test "a device without address is unknown and never pinged", context do
    device = %{context.device | interfaces: []}

    assert %Status{state: :unknown} = Reachability.check(device, server: context.server)
    refute_receive {:pinged, _address}, 50
  end
end
