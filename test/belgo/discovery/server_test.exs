defmodule Belgo.Discovery.ServerTest do
  # Lowers the global log level in one test, so it cannot run concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Belgo.Discovery
  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.Server
  alias Belgo.Fixtures
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.Storage.YamlDirectory
  alias Belgo.Inventory.Store

  @moduletag :tmp_dir
  @environment %{"BELGO_OPNSENSE_API_KEY" => "homer", "BELGO_OPNSENSE_API_SECRET" => "donuts"}

  setup %{tmp_dir: tmp_dir} do
    for collection <- Snapshot.collections(),
        do: :ok = YamlDirectory.save([path: tmp_dir], Fixtures.snapshot(), collection)

    inventory = start_supervised!({Store, storage: {YamlDirectory, path: tmp_dir}, name: nil})
    topic = "discovery-#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Belgo.PubSub, topic)

    {:ok, inventory: inventory, topic: topic}
  end

  defp start_server(context, url, extra_options \\ "", server_options \\ []) do
    File.write!(
      Path.join(context.tmp_dir, "providers.yaml"),
      "version: 1\nproviders:\n  opnsense:\n    url: #{url}\n" <> extra_options
    )

    options =
      Keyword.merge(
        [
          directory: context.tmp_dir,
          inventory: context.inventory,
          environment: @environment,
          pubsub: Belgo.PubSub,
          topic: context.topic,
          refresh_on_start: false,
          name: nil
        ],
        server_options
      )

    start_supervised!({Server, options})
  end

  defp await_pull do
    assert_receive {:discovery_changed,
                    %{providers: [%{running?: false, completed_at: %DateTime{}}]} = state},
                   1_000

    state
  end

  test "pulls providers and logs the start and the success", context do
    server = start_server(context, "https://opnsense.springfield.lan")
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log([level: :debug], fn ->
        Discovery.refresh(server)
        state = await_pull()

        assert ["barney-laptop", "moe-pc", "nelson-iphone"] ==
                 Enum.map(state.correlation.unknown_devices, & &1.hostname)
      end)

    assert log =~ "[debug] [discovery] [opnsense] started"

    assert log =~
             ~r/\[info\] \[discovery\] \[opnsense\] completed in \d+ms: 2 kea_lease, 4 kea_reservation, 2 kea_subnet, 2 opnsense_gateway, 4 unbound_host_override/
  end

  test "pings the unknown devices after a pull", context do
    test_process = self()

    reachability =
      start_supervised!(
        {Belgo.Reachability.Server,
         directory: context.tmp_dir,
         name: nil,
         ping: fn address, _timeout ->
           send(test_process, {:pinged, address})
           :down
         end}
      )

    server =
      start_server(context, "https://opnsense.springfield.lan", "", reachability: reachability)

    Discovery.refresh(server)
    state = await_pull()
    addresses = Correlation.discovered_addresses(state.correlation)
    assert addresses != []

    for address <- addresses, do: assert_receive({:pinged, ^address}, 1_000)
  end

  test "logs failures and exposes them", context do
    server = start_server(context, "https://broken.example")

    log =
      capture_log(fn ->
        Discovery.refresh(server)

        assert %{providers: [%{error: [{:kea, {:http_status, _path, 401}} | _unbound]}]} =
                 await_pull()
      end)

    assert log =~
             ~r/\[error\] \[discovery\] \[opnsense\] failed after \d+ms: \[kea: \{:http_status/
  end

  test "ignoring a device goes to the denylist and is applied right away", context do
    server = start_server(context, "https://opnsense.springfield.lan")
    Discovery.refresh(server)
    state = await_pull()

    {:ok, nelson} =
      Belgo.Discovery.Correlation.fetch_device(state.correlation, "mac-02-00-00-00-06-66")

    assert {:ok, [%{id: "02:00:00:00:06:66", name: "nelson-iphone"}]} =
             Discovery.ignore(nelson, user: :system, transaction: [server: context.inventory])

    send(server, {:inventory_changed, Belgo.Inventory.snapshot(context.inventory)})

    assert_receive {:discovery_changed,
                    %{correlation: %{ignored_devices: [%{id: "mac-02-00-00-00-06-66"}]}}},
                   1_000

    assert {:ok, [_entry]} =
             Discovery.stop_ignoring(nelson,
               user: :system,
               transaction: [server: context.inventory]
             )
  end

  test "an invalid providers.yaml is reported without stopping the server", context do
    File.write!(
      Path.join(context.tmp_dir, "providers.yaml"),
      "version: 1\nproviders:\n  opnsense: {}\n"
    )

    server =
      start_supervised!(
        {Server,
         directory: context.tmp_dir,
         inventory: context.inventory,
         environment: %{},
         pubsub: Belgo.PubSub,
         topic: context.topic,
         refresh_on_start: false,
         name: nil}
      )

    log =
      capture_log(fn ->
        Discovery.refresh(server)
        assert_receive {:discovery_changed, %{providers: [], settings_errors: [_ | _]}}, 1_000
      end)

    assert log =~ "[discovery] invalid providers configuration"
  end

  test "pushes a device to write providers and logs it", context do
    server = start_server(context, "https://opnsense.springfield.lan", "    mode: write\n")
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log([level: :debug], fn ->
        Discovery.push_device("smithers", server)

        assert_receive {:discovery_changed,
                        %{
                          providers: [
                            %{
                              mode: :write,
                              last_push: %{device_id: "smithers", result: {:ok, _report}}
                            }
                          ]
                        }},
                       1_000
      end)

    assert log =~ "[debug] [push] [opnsense] [smithers] started"

    assert log =~
             ~r/\[info\] \[push\] \[opnsense\] \[smithers\] completed in \d+ms: update reservation/
  end

  test "releases MAC addresses the inventory no longer has", context do
    server =
      start_server(
        context,
        "https://opnsense.springfield.lan",
        "    mode: write\n    delete_reservation: interface_deletion\n"
      )

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log([level: :info], fn ->
        # Smithers' MAC is still in the inventory: kept.
        Discovery.release_mac_addresses(
          {:devices, "moe-pc"},
          ["02:00:00:00:05:01", "02:00:00:00:00:11"],
          server
        )

        assert_receive {:discovery_changed,
                        %{providers: [%{last_push: %{device_id: "moe-pc", result: {:ok, _}}}]}},
                       1_000
      end)

    assert log =~ "[push] [opnsense] [moe-pc] completed"
    assert log =~ "delete reservation 02:00:00:00:05:01"
    refute log =~ "02:00:00:00:00:11"
  end

  test "read providers are never pushed to", context do
    server = start_server(context, "https://opnsense.springfield.lan")
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log([level: :debug], fn ->
        Discovery.push_device("smithers", server)
        assert %{providers: [%{mode: :read, last_push: nil}]} = Discovery.state(server)
      end)

    assert log =~ "[push] [smithers] skipped, no provider in write mode"
    refute log =~ "[push] [opnsense]"
  end

  test "providers with an interval are pulled again", context do
    server = start_server(context, "https://opnsense.springfield.lan", "    interval: 10s\n")
    Discovery.refresh(server)
    await_pull()

    assert %{timers: %{opnsense: timer}} = :sys.get_state(server)
    assert is_reference(timer)

    send(server, {:scheduled_pull, :opnsense})
    assert %{providers: [%{running?: false}]} = await_pull()
  end

  test "providers without interval are not scheduled", context do
    server = start_server(context, "https://opnsense.springfield.lan")
    Discovery.refresh(server)
    await_pull()

    assert %{timers: timers} = :sys.get_state(server)
    assert timers == %{}
  end

  test "refresh_provider/2 pulls only the given provider", context do
    File.write!(
      Path.join(context.tmp_dir, "providers.yaml"),
      "version: 1\nproviders:\n  opnsense:\n    url: https://opnsense.springfield.lan\n" <>
        "  home_assistant:\n    url: https://homeassistant.springfield.lan\n"
    )

    server =
      start_supervised!(
        {Server,
         directory: context.tmp_dir,
         inventory: context.inventory,
         environment: Map.put(@environment, "BELGO_HOME_ASSISTANT_TOKEN", "mmm-donuts"),
         pubsub: Belgo.PubSub,
         topic: context.topic,
         refresh_on_start: false,
         name: nil}
      )

    Discovery.refresh_provider(:home_assistant, server)

    assert_receive {:discovery_changed, %{providers: providers}} when length(providers) == 2,
                   1_000

    assert %{running?: true} = Enum.find(providers, &(&1.key == :home_assistant))
    assert %{running?: false, completed_at: nil} = Enum.find(providers, &(&1.key == :opnsense))
  end
end
