defmodule Belgo.AmtTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Belgo.Amt
  alias Belgo.Amt.Credentials
  alias Belgo.Amt.Detection
  alias Belgo.Amt.Info
  alias Belgo.Amt.Target
  alias Belgo.Fixtures.WsmanClient
  alias Belgo.PortScan.AddressScan

  @target %Target{address: "10.0.0.10"}

  test "reads the power state and the machine information" do
    assert {:ok, %Info{} = info} = Amt.status(@target, Credentials.new("admin", "excellent"))

    assert %Info{
             power_state: :on,
             firmware_version: "11.8.55",
             firmware_build: "3510",
             manufacturer: "Excellent Computers",
             model: "Nuclear 1",
             serial_number: "SN-1895",
             bios_version: "1.0.7",
             bios_release_date: "1989-12-17T00:00:00Z",
             processors: ["Intel(R) Core(TM) i5-7500T"],
             memory_bytes: 17_179_869_184
           } = info

    assert "11.8.55.3510" == Info.full_firmware_version(info)
    assert :not_vulnerable == Info.vulnerability(info)
  end

  test "powers the machine and reads the state back" do
    Phoenix.PubSub.subscribe(Belgo.PubSub, WsmanClient.topic())

    assert {:ok, :on} == Amt.power(@target, Credentials.new("admin", "excellent"), :power_cycle)
    assert_receive {:amt_power_requested, 5}

    assert {:ok, :on} == Amt.power(@target, Credentials.new(nil, "excellent"), :power_off)
    assert_receive {:amt_power_requested, 8}
  end

  test "a refused account stops at the first request and is never logged" do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log([level: :debug], fn ->
        assert {:error, :unauthorized} ==
                 Amt.status(@target, Credentials.new("admin", "mmm-donuts"),
                   device_id: "burns-node",
                   username: "smithers"
                 )
      end)

    assert log =~ "[amt] [status] [burns-node] [smithers] reading 10.0.0.10"
    assert log =~ "[amt] [status] [burns-node] [smithers] failed: :unauthorized"
    refute log =~ "mmm-donuts"
  end

  test "TLS without CA file is refused before any request" do
    target = %Target{address: "10.0.0.10", wsman_tls?: true}

    capture_log(fn ->
      assert {:error, :ca_file_missing} ==
               Amt.status(target, Credentials.new("admin", "excellent"))
    end)
  end

  test "credentials never show their password" do
    refute inspect(Credentials.new("admin", "excellent")) =~ "excellent"
    assert "excellent" == Credentials.password(Credentials.new("admin", "excellent"))
    assert "admin" == Credentials.new("", "excellent").username
  end

  test "finds the first detection among the scans of a device's addresses" do
    detection = %Detection{address: "10.0.0.10", open_ports: [16_992]}

    scans = %{
      "10.0.0.9" => %AddressScan{address: "10.0.0.9", state: :done},
      "10.0.0.10" => %AddressScan{address: "10.0.0.10", state: :done, amt: detection}
    }

    assert detection == Amt.detection(scans, ["10.0.0.9", "10.0.0.10"])
    assert nil == Amt.detection(scans, ["10.0.0.9"])
  end
end
