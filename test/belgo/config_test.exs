defmodule Belgo.ConfigTest do
  use ExUnit.Case, async: true

  alias Belgo.Config
  alias Belgo.Config.Git
  alias Belgo.Config.Ping
  alias Belgo.Config.PortScan
  alias Belgo.Config.WakeOnLan
  alias Belgo.Duration

  @moduletag :tmp_dir

  test "defaults without file: pings are reused for 15 minutes", %{tmp_dir: tmp_dir} do
    assert {:ok, %Config{ping: %Ping{cache_duration: 900_000, timeout: 2_000}}} =
             Config.load(tmp_dir)
  end

  test "reads durations from config.yaml" do
    assert {:ok, %Config{ping: %Ping{cache_duration: 3_600_000, timeout: 5_000}}} =
             Config.parse(%{
               "version" => 1,
               "ping" => %{"cache_duration" => "1h", "timeout" => 5}
             })
  end

  test "rejects invalid values and versions" do
    assert {:error, [message]} =
             Config.parse(%{"version" => 1, "ping" => %{"cache_duration" => "a while"}})

    assert message =~ "ping.cache_duration"
    assert {:error, _messages} = Config.parse(%{"version" => 2})
  end

  test "durations accept seconds, minutes and hours" do
    assert {:ok, 30_000} == Duration.parse("30s")
    assert {:ok, 900_000} == Duration.parse("15m")
    assert {:ok, 7_200_000} == Duration.parse("2h")
    assert {:ok, 45_000} == Duration.parse(45)
    assert :error == Duration.parse("soon")
  end

  test "theme is auto by default, light or dark when set" do
    assert {:ok, %Config{theme: :auto}} = Config.parse(%{"version" => 1})
    assert {:ok, %Config{theme: :dark}} = Config.parse(%{"version" => 1, "theme" => "dark"})
    assert {:ok, %Config{theme: :light}} = Config.parse(%{"version" => 1, "theme" => "light"})
    assert {:error, [message]} = Config.parse(%{"version" => 1, "theme" => "neon"})
    assert message =~ "theme must be auto, light or dark"
  end

  test "git is disabled without the key, defaults when the key is empty" do
    assert {:ok, %Config{git: nil}} = Config.parse(%{"version" => 1})

    assert {:ok, %Config{git: %Git{commit_delay: 300_000, push_interval: 3_600_000, remote: nil}}} =
             Config.parse(%{"version" => 1, "git" => nil})
  end

  test "reads the git remote and durations" do
    assert {:ok,
            %Config{
              git: %Git{
                commit_delay: 60_000,
                push_interval: 7_200_000,
                remote: "git@github.com:simpson/homelab.git",
                branch: "springfield",
                author_name: "Homer Simpson"
              }
            }} =
             Config.parse(%{
               "version" => 1,
               "git" => %{
                 "commit_delay" => "1m",
                 "push_interval" => "2h",
                 "remote" => "git@github.com:simpson/homelab.git",
                 "branch" => "springfield",
                 "author_name" => "Homer Simpson"
               }
             })
  end

  test "rejects invalid git settings" do
    assert {:error, [delay_message, remote_message]} =
             Config.parse(%{
               "version" => 1,
               "git" => %{"commit_delay" => "later", "remote" => ""}
             })

    assert delay_message =~ "git.commit_delay"
    assert remote_message =~ "git.remote"
    assert {:error, [message]} = Config.parse(%{"version" => 1, "git" => "yes"})
    assert message =~ "git must be a map"
  end

  test "wake-on-LAN and port scan durations have defaults and can be set" do
    assert {:ok,
            %Config{
              wake_on_lan: %WakeOnLan{ping_interval: 5_000, timeout: 60_000},
              port_scan: %PortScan{cache_duration: 3_600_000, timeout: 1_000}
            }} = Config.parse(%{"version" => 1})

    assert {:ok,
            %Config{
              wake_on_lan: %WakeOnLan{ping_interval: 10_000, timeout: 120_000},
              port_scan: %PortScan{cache_duration: 1_800_000, timeout: 500_000}
            }} =
             Config.parse(%{
               "version" => 1,
               "wake_on_lan" => %{"ping_interval" => "10s", "timeout" => "2m"},
               "port_scan" => %{"cache_duration" => "30m", "timeout" => 500}
             })

    assert {:error, [message]} =
             Config.parse(%{"version" => 1, "wake_on_lan" => %{"ping_interval" => "0s"}})

    assert message =~ "wake_on_lan.ping_interval"
  end

  test "the plan editor saves after 5 seconds by default" do
    assert {:ok, %Config{plan: %Belgo.Config.Plan{autosave_delay: 5_000}}} =
             Config.parse(%{"version" => 1})

    assert {:ok, %Config{plan: %Belgo.Config.Plan{autosave_delay: 10_000}}} =
             Config.parse(%{"version" => 1, "plan" => %{"autosave_delay" => "10s"}})
  end
end
