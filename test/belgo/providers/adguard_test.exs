defmodule Belgo.Providers.AdguardTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.Observation
  alias Belgo.Discovery.Suggestion
  alias Belgo.Fixtures
  alias Belgo.Fixtures.AdguardClient
  alias Belgo.Fixtures.OpnsenseClient
  alias Belgo.Inventory.Snapshot
  alias Belgo.Providers.Adguard
  alias Belgo.Providers.Adguard.Push
  alias Belgo.Providers.Adguard.Translate
  alias Belgo.Providers.Opnsense
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.PushReport

  defp config(url \\ "https://adguard.springfield.lan") do
    %Adguard.Config{url: url, username: "marge", password: "pretzels", client: AdguardClient}
  end

  defp summaries(%{operations: operations}), do: Enum.map(operations, & &1.summary)

  test "parses its configuration" do
    environment = %{"BELGO_ADGUARD_USERNAME" => "marge", "BELGO_ADGUARD_PASSWORD" => "pretzels"}

    assert {:ok, %Adguard.Config{url: "https://adguard", username: "marge", verify_tls: true}} =
             Adguard.parse_config(%{"url" => "https://adguard/"}, environment)

    assert {:error, messages} =
             Adguard.parse_config(%{"url" => "https://adguard", "mode" => "x"}, %{})

    assert "unknown options: mode (expected url, verify_tls)" in messages
    assert "missing secret: set BELGO_ADGUARD_PASSWORD or BELGO_ADGUARD_PASSWORD_FILE" in messages
  end

  test "keeps enabled address rewrites only" do
    assert [
             %Observation{
               source: :adguard_rewrite,
               hostname: "duff",
               domain: "springfield.lan",
               ip: "10.0.0.50"
             },
             %Observation{hostname: "assistant", ip: "10.0.0.11"},
             %Observation{hostname: "smithers", ip: "10.0.0.12"}
           ] = Translate.rewrites(AdguardClient.rewrites())
  end

  test "persistent clients link their MAC and IP addresses, auto clients bring their IP and name" do
    observations = Translate.clients(AdguardClient.clients())

    assert [
             {:adguard_client, "02:00:00:00:00:30", nil, nil, "Lisa's computer"},
             {:adguard_client, "02:00:00:00:09:09", "10.0.0.90", nil, "Ralph Tablet"},
             {:adguard_client, "02:00:00:00:09:09", "10.0.0.91", nil, "Ralph Tablet"},
             {:adguard_client, nil, "10.0.0.20", nil, "Milhouse Phone"},
             {:adguard_client, "02:00:00:00:00:20", nil, nil, "Living Room TV"},
             {:adguard_auto_client, nil, "10.0.0.66", "bart-console", "rDNS"},
             {:adguard_auto_client, nil, "10.0.0.67", nil, "ARP"}
           ] == Enum.map(observations, &{&1.source, &1.mac, &1.ip, &1.hostname, &1.description})
  end

  test "discover/1 reports partial failures and fails when everything fails" do
    assert {:ok,
            %{
              counts: %{adguard_rewrite: 3, adguard_client: 5, adguard_auto_client: 2},
              failures: []
            }} =
             Adguard.discover(config())

    assert {:error, [rewrites: _reason, clients: _other_reason]} =
             Adguard.discover(config("https://broken.example"))
  end

  test "correlates with OPNsense and the inventory" do
    {:ok, opnsense} =
      Opnsense.discover(%Opnsense.Config{
        url: "https://opnsense",
        api_key: "k",
        api_secret: "s",
        client: OpnsenseClient
      })

    {:ok, adguard} = Adguard.discover(config())
    snapshot = Fixtures.snapshot()
    correlation = Correlation.build(snapshot, opnsense.observations ++ adguard.observations)

    {:ok, moe} = Correlation.fetch_device(correlation, "mac-02-00-00-00-05-01")

    assert "duff, moe-pc, tavern" ==
             get_in(Suggestion.device_params(moe, snapshot), ["interfaces", "0", "dns_names"])

    {:ok, ralph} = Correlation.fetch_device(correlation, "mac-02-00-00-00-09-09")
    assert ["10.0.0.90", "10.0.0.91"] == ralph.ips
    assert "Ralph Tablet" == ralph.description

    {:ok, unnamed} = Correlation.fetch_device(correlation, "ip-10-0-0-67")
    assert [:adguard_auto_client] == Enum.map(unnamed.observations, & &1.source)

    assert "client name is Lisa's computer, Belgo has Lisa Laptop" in Enum.map(
             Correlation.divergences_for(correlation, :devices, "lisa-laptop"),
             & &1.message
           )

    assert "smithers.springfield.lan resolves to 10.0.0.12, Belgo expects 10.0.0.11" in Enum.map(
             Correlation.divergences_for(correlation, :devices, "smithers"),
             & &1.message
           )
  end

  test "plans persistent clients: create missing, update differing, skip ambiguous ones" do
    plan = Push.plan(DesiredState.build(Fixtures.snapshot()), AdguardClient.clients())

    assert [
             "create client Burns Node (02:00:00:00:00:10, 10.0.0.10)",
             "update client Lisa's computer (name: Lisa's computer → Lisa Laptop; tags: [device_pc, user_child] → [device_laptop, user_child])",
             "create client Plow King (02:00:00:00:00:02, 10.0.0.2)",
             "create client Power Plant (10.0.0.1)",
             "create client Smithers (02:00:00:00:00:11, 10.0.0.11)"
           ] == summaries(plan)

    assert ["TV Living Room: matches several AdGuard clients (Milhouse Phone, Living Room TV)"] ==
             plan.skipped
  end

  test "updates send the whole existing client with only managed fields changed" do
    plan = Push.plan(DesiredState.build(Fixtures.snapshot()), AdguardClient.clients())

    assert %Push.Operation{
             path: "/control/clients/update",
             body: %{
               "name" => "Lisa's computer",
               "data" => %{
                 "name" => "Lisa Laptop",
                 "ids" => ["02:00:00:00:00:30", "lisa-doh"],
                 "tags" => ["device_laptop", "user_child"],
                 "use_global_settings" => false,
                 "filtering_enabled" => true,
                 "parental_enabled" => true,
                 "blocked_services" => ["tiktok"],
                 "upstreams" => ["9.9.9.9"]
               }
             }
           } = Enum.find(plan.operations, &(&1.path == "/control/clients/update"))

    assert %Push.Operation{
             body: %{
               "name" => "Smithers",
               "ids" => ["02:00:00:00:00:11", "10.0.0.11"],
               "tags" => ["device_other"],
               "use_global_settings" => true
             }
           } = Enum.find(plan.operations, &(&1.summary =~ "create client Smithers"))
  end

  test "Belgo tags supported by AdGuard are added, others ignored" do
    snapshot =
      Snapshot.put(
        Fixtures.snapshot(),
        :devices,
        Fixtures.device(tags: ["os_linux", "beer"], interfaces: [Fixtures.interface()])
      )

    plan =
      snapshot
      |> DesiredState.build()
      |> DesiredState.for_device("homer-pc")
      |> Push.plan(AdguardClient.clients())

    assert [%Push.Operation{body: %{"tags" => ["device_pc", "os_linux"]}}] = plan.operations
  end

  test "gaming devices are tagged as game consoles" do
    snapshot =
      Snapshot.put(
        Fixtures.snapshot(),
        :devices,
        Fixtures.device(
          id: "bart-switch",
          name: "Bart Switch",
          kind: :gaming,
          interfaces: [Fixtures.interface()]
        )
      )

    plan =
      snapshot
      |> DesiredState.build()
      |> DesiredState.for_device("bart-switch")
      |> Push.plan(AdguardClient.clients())

    assert [%Push.Operation{body: %{"tags" => ["device_gameconsole"]}}] = plan.operations
  end

  test "cameras are tagged as cameras" do
    snapshot =
      Snapshot.put(
        Fixtures.snapshot(),
        :devices,
        Fixtures.device(
          id: "springfield-nuclear-cam",
          name: "Springfield Nuclear Cam",
          kind: :camera,
          interfaces: [Fixtures.interface()]
        )
      )

    plan =
      snapshot
      |> DesiredState.build()
      |> DesiredState.for_device("springfield-nuclear-cam")
      |> Push.plan(AdguardClient.clients())

    assert [%Push.Operation{body: %{"tags" => ["device_camera"]}}] = plan.operations
  end

  test "push/2 writes the clients of a device" do
    desired_state =
      DesiredState.for_device(DesiredState.build(Fixtures.snapshot()), "lisa-laptop")

    assert {:ok, %PushReport{provider: :adguard} = report} = Adguard.push(config(), desired_state)
    assert [_update] = report.operations

    assert_received {:adguard_request, :post, "/control/clients/update",
                     %{"name" => "Lisa's computer"}}
  end

  test "a device already in sync writes nothing" do
    synced = %{
      "clients" => [
        %{
          "name" => "Smithers",
          "ids" => ["02:00:00:00:00:11", "10.0.0.11"],
          "tags" => ["device_other"]
        }
      ],
      "supported_tags" => ["device_other"]
    }

    desired_state = DesiredState.for_device(DesiredState.build(Fixtures.snapshot()), "smithers")

    assert %{operations: [], skipped: []} = Push.plan(desired_state, synced)
  end

  test "push/2 does not call AdGuard for a device without address" do
    desired_state =
      DesiredState.for_device(DesiredState.build(Fixtures.snapshot()), "bart-console")

    assert {:ok, %PushReport{operations: []}} =
             Adguard.push(config("https://broken.example"), desired_state)
  end
end
