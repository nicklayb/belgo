defmodule Belgo.ClientControlsTest do
  use ExUnit.Case, async: true

  alias Belgo.ClientControls
  alias Belgo.Fixtures
  alias Belgo.Fixtures.OmadaClient
  alias Belgo.Inventory.Snapshot
  alias Belgo.Providers.Omada

  @environment %{
    "BELGO_OMADA_CLIENT_ID" => "ned",
    "BELGO_OMADA_CLIENT_SECRET" => "okilydokily"
  }

  defp observations do
    config = %Omada.Config{
      url: "https://omada.springfield.lan:8043",
      client_id: "ned",
      client_secret: "okilydokily",
      client: OmadaClient
    }

    {:ok, report} = Omada.discover(config)
    report.observations
  end

  defp device(id) do
    {:ok, device} = Snapshot.fetch(Fixtures.snapshot(), :devices, id)
    device
  end

  defp write_providers(directory, mode) do
    File.write!(
      Path.join(directory, "providers.yaml"),
      "version: 1\nproviders:\n  omada:\n    mode: #{mode}\n    url: https://omada.springfield.lan\n"
    )

    [directory: directory, environment: @environment]
  end

  defp lisa_client, do: hd(ClientControls.clients(observations(), device("lisa-laptop")))

  test "lists the controller clients of the device's MAC addresses" do
    assert [%{mac: "02:00:00:00:00:30", wireless: true} = lisa] =
             ClientControls.clients(observations(), device("lisa-laptop"))

    assert ClientControls.reconnectable?(lisa)

    assert [%{mac: "02:00:00:00:00:10", wireless: false} = burns] =
             ClientControls.clients(observations(), device("burns-node"))

    refute ClientControls.reconnectable?(burns)
  end

  @tag :tmp_dir
  test "reconnects a wireless client through a provider in write mode", %{tmp_dir: directory} do
    Phoenix.PubSub.subscribe(Belgo.PubSub, OmadaClient.reconnect_topic())

    assert :ok == ClientControls.reconnect(lisa_client(), write_providers(directory, "write"))
    assert_receive {:omada_reconnect, "02-00-00-00-00-30"}
  end

  @tag :tmp_dir
  test "refuses providers in read mode and wired clients", %{tmp_dir: directory} do
    Phoenix.PubSub.subscribe(Belgo.PubSub, OmadaClient.reconnect_topic())

    assert {:error, :not_writable} ==
             ClientControls.reconnect(lisa_client(), write_providers(directory, "read"))

    [burns] = ClientControls.clients(observations(), device("burns-node"))

    assert {:error, :not_wireless} ==
             ClientControls.reconnect(burns, write_providers(directory, "write"))

    refute_receive {:omada_reconnect, _mac}
  end
end
