defmodule Belgo.WakeOnLan.WatchTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Interface
  alias Belgo.WakeOnLan.Outcome
  alias Belgo.WakeOnLan.Watch

  @device %Device{
    id: "burns-node",
    name: "Burns Node",
    kind: :server,
    interfaces: [%Interface{mac: "02:00:00:00:00:10", ip: "10.0.0.10"}]
  }

  setup do
    pubsub = __MODULE__.PubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    topic = "wake:#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(pubsub, topic)
    %{pubsub: pubsub, topic: topic}
  end

  test "announces the device once it answers", %{pubsub: pubsub, topic: topic} do
    attempts = :counters.new(1, [])
    test_process = self()

    # Answers on the third ping.
    ping = fn "10.0.0.10", _timeout ->
      :counters.add(attempts, 1, 1)
      if :counters.get(attempts, 1) >= 3, do: :up, else: :down
    end

    start_watch(pubsub, topic,
      ping: ping,
      ping_interval: 10,
      timeout: 5_000,
      on_awake: &send(test_process, {:awake, &1})
    )

    assert_receive {:wake_on_lan, %Outcome{device_id: "burns-node", result: :awake}}, 1_000
    assert_received {:awake, ["10.0.0.10"]}
    assert 3 == :counters.get(attempts, 1)
  end

  test "gives up after the timeout", %{pubsub: pubsub, topic: topic} do
    start_watch(pubsub, topic,
      ping: fn _address, _timeout -> :down end,
      ping_interval: 10,
      timeout: 50
    )

    assert_receive {:wake_on_lan, %Outcome{result: :timeout, elapsed: elapsed}}, 1_000
    assert elapsed >= 50
  end

  defp start_watch(pubsub, topic, options) do
    start_supervised!(
      {Watch,
       Keyword.merge(
         [device: @device, ping_timeout: 10, pubsub: pubsub, topic: topic],
         options
       )}
    )
  end
end
