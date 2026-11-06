defmodule Belgo.Fixtures.OmadaClient do
  @moduledoc """
  Omada controller returning Springfield devices: an Omada gateway, the attic PoE
  switch on its port 3, the ground floor access point on the switch port 8. Clients:
  a HomePod on the access point (locked to it), Burns Node wired on the switch port
  5, Lisa's laptop roaming. Renames are sent to the calling process as
  `{:omada_rename, mac, name}`. The `broken.example` controller refuses the token.
  """

  @behaviour Belgo.Providers.Omada.Client

  @impl Belgo.Providers.Omada.Client
  def open(%{url: "https://broken.example"}),
    do: {:error, {:omada_error, -44_106, "The client id or client secret is invalid."}}

  def open(config), do: {:ok, %{site: config.site}}

  @impl Belgo.Providers.Omada.Client
  def devices(_session) do
    {:ok,
     [
       %{
         "type" => "gateway",
         "mac" => "AA-00-00-00-00-01",
         "name" => "Omada Gateway",
         "ip" => "10.0.0.1"
       },
       %{
         "type" => "switch",
         "mac" => "AA-00-00-00-00-02",
         "name" => "Switch PoE Attic",
         "ip" => "10.0.0.3",
         "uplinkDeviceMac" => "AA-00-00-00-00-01",
         "uplinkDeviceName" => "Omada Gateway",
         "uplinkDevicePort" => "3"
       },
       %{
         "type" => "ap",
         "mac" => "AA-00-00-00-00-03",
         "name" => "AP Ground Floor",
         "ip" => "10.0.0.4",
         "uplinkDeviceMac" => "AA-00-00-00-00-02",
         "uplinkDeviceName" => "Switch PoE Attic",
         "uplinkDevicePort" => "8"
       }
     ]}
  end

  @impl Belgo.Providers.Omada.Client
  def clients(_session) do
    {:ok,
     [
       %{
         "mac" => "02-00-00-00-00-77",
         "name" => "HomePod Mini",
         "hostName" => "homepod-mini",
         "ip" => "10.0.0.77",
         "wireless" => true,
         "apMac" => "AA-00-00-00-00-03",
         "apName" => "AP Ground Floor",
         "ssid" => "Springfield",
         "clientLockToApSetting" => %{"enable" => true, "aps" => ["AA-00-00-00-00-03"]}
       },
       %{
         "mac" => "02-00-00-00-00-10",
         "name" => "Mr Burns",
         "ip" => "10.0.0.10",
         "wireless" => false,
         "switchMac" => "AA-00-00-00-00-02",
         "switchName" => "Switch PoE Attic",
         "port" => 5
       },
       %{
         "mac" => "02-00-00-00-00-30",
         "name" => "02-00-00-00-00-30",
         "ip" => "10.0.0.30",
         "wireless" => true,
         "apMac" => "AA-00-00-00-00-03",
         "apName" => "AP Ground Floor",
         "ssid" => "Springfield",
         "clientLockToApSetting" => %{"enable" => false}
       }
     ]}
  end

  @impl Belgo.Providers.Omada.Client
  def rename_client(_session, mac, name) do
    send(self(), {:omada_rename, mac, name})
    {:ok, nil}
  end
end
