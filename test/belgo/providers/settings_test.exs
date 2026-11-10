defmodule Belgo.Providers.SettingsTest do
  use ExUnit.Case, async: true

  alias Belgo.Providers.Opnsense
  alias Belgo.Providers.Secrets
  alias Belgo.Providers.Settings
  alias Belgo.Providers.Settings.Configured

  @environment %{"BELGO_OPNSENSE_API_KEY" => "homer", "BELGO_OPNSENSE_API_SECRET" => "donuts"}

  describe "Secrets.fetch/3" do
    test "prefers the variable, then the file" do
      read_file = fn "/run/secrets/key" -> {:ok, "from-file\n"} end

      assert {:ok, "direct"} ==
               Secrets.fetch(
                 "KEY",
                 %{"KEY" => "direct", "KEY_FILE" => "/run/secrets/key"},
                 read_file
               )

      assert {:ok, "from-file"} ==
               Secrets.fetch("KEY", %{"KEY_FILE" => "/run/secrets/key"}, read_file)

      assert {:error, "missing secret: set KEY or KEY_FILE"} ==
               Secrets.fetch("KEY", %{}, read_file)
    end

    test "reports unreadable files" do
      read_file = fn _path -> {:error, :enoent} end

      assert {:error, "unable to read KEY_FILE (/nope): enoent"} ==
               Secrets.fetch("KEY", %{"KEY_FILE" => "/nope"}, read_file)
    end
  end

  test "no providers section means no provider" do
    assert {:ok, %Settings{configs: []}} == Settings.parse(%{"version" => 1}, @environment)
  end

  test "parses OPNsense with its secrets, without leaking them when inspected" do
    document = %{
      "version" => 1,
      "providers" => %{
        "opnsense" => %{"url" => "https://opnsense.springfield.lan/", "verify_tls" => false}
      }
    }

    assert {:ok, %Settings{configs: [%Configured{module: Opnsense, mode: :read, config: config}]}} =
             Settings.parse(document, @environment)

    assert %Opnsense.Config{
             url: "https://opnsense.springfield.lan",
             api_key: "homer",
             verify_tls: false
           } = config

    refute inspect(config) =~ "donuts"
  end

  test "disabled providers are skipped" do
    document = %{"version" => 1, "providers" => %{"opnsense" => %{"mode" => "disabled"}}}

    assert {:ok, %Settings{configs: []}} == Settings.parse(document, %{})
  end

  test "reports every problem" do
    document = %{
      "version" => 1,
      "providers" => %{"opnsense" => %{"url" => "ftp://plant"}, "kwik-e-mart" => %{}}
    }

    assert {:error, messages} = Settings.parse(document, %{})
    assert "providers.yaml (kwik-e-mart): unknown provider" in messages
    assert "providers.yaml (opnsense): url must be an http(s) URL" in messages

    assert "providers.yaml (opnsense): missing secret: set BELGO_OPNSENSE_API_KEY or BELGO_OPNSENSE_API_KEY_FILE" in messages
  end

  test "parses the mode, read by default, and rejects unknown options and modes" do
    document = %{
      "version" => 1,
      "providers" => %{"opnsense" => %{"url" => "https://opnsense", "mode" => "write"}}
    }

    assert {:ok, %Settings{configs: [%Configured{mode: :write}]} = settings} =
             Settings.parse(document, @environment)

    assert [%Configured{module: Opnsense}] = Settings.writable(settings)

    assert {:error, ["providers.yaml (opnsense): mode must be disabled, read or write"]} ==
             Settings.parse(
               put_in(document, ["providers", "opnsense", "mode"], "maybe"),
               @environment
             )

    assert {:error,
            [
              "providers.yaml (opnsense): unknown options: dry_run (expected url, verify_tls, delete_reservation, wake_on_lan)"
            ]} ==
             Settings.parse(
               put_in(document, ["providers", "opnsense", "dry_run"], true),
               @environment
             )
  end

  test "parses the interval of every provider" do
    document = fn interval ->
      %{
        "version" => 1,
        "providers" => %{"opnsense" => %{"url" => "https://opnsense", "interval" => interval}}
      }
    end

    assert {:ok, %Settings{configs: [%Configured{interval: 300_000}]}} =
             Settings.parse(document.("5m"), @environment)

    assert {:ok, %Settings{configs: [%Configured{interval: 45_000}]}} =
             Settings.parse(document.(45), @environment)

    assert {:ok, %Settings{configs: [%Configured{interval: 3_600_000}]}} =
             Settings.parse(document.("1h"), @environment)

    assert {:error, ["providers.yaml (opnsense): interval must be at least 10s"]} ==
             Settings.parse(document.("5s"), @environment)

    assert {:error, ["providers.yaml (opnsense): interval must look like 30s, 5m or 1h"]} ==
             Settings.parse(document.("often"), @environment)
  end
end
