defmodule Belgo.ConfigTest do
  use ExUnit.Case, async: true

  alias Belgo.Config
  alias Belgo.Config.Ping
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
end
