defmodule Belgo.Providers.Omada.Translate do
  @moduledoc """
  Turns Omada Open API rows into observations. Pure functions only.

  Field names follow the Open API 6.3.0 documentation: devices have `type` (`ap`,
  `gateway`, `switch`), `mac`, `name`, `ip`, `uplinkDeviceMac`, `uplinkDeviceName`,
  `uplinkDevicePort`; clients have `mac`, `name`, `hostName`, `ip`, `wireless`, then
  `apMac`/`apName`/`ssid` (Wi-Fi), `switchMac`/`switchName`/`port` (wired on a
  switch) or `gatewayMac`/`gatewayName`/`port` (wired on the gateway), and
  `clientLockToApSetting.enable`, and what Omada recognised: `deviceType`,
  `deviceCategory`, `vendor`, `model` (mapped to a Belgo kind by
  `Omada.DeviceTypes`). MAC addresses look like `AA-BB-CC-DD-EE-FF`.
  """

  alias Belgo.Discovery.Observation
  alias Belgo.Inventory.Interface
  alias Belgo.Network.IpAddress
  alias Belgo.Network.MacAddress
  alias Belgo.Providers.Omada.DeviceTypes

  @provider :omada
  @role_by_type %{"gateway" => :gateway, "switch" => :switch, "ap" => :access_point}

  @doc "Site devices (gateway, switches, access points) become network device observations."
  @spec devices(any()) :: [Observation.t()]
  def devices(devices) when is_list(devices), do: Enum.flat_map(devices, &device/1)
  def devices(_devices), do: []

  defp device(%{} = device) do
    with role when role != nil <- role(device["type"]),
         mac when mac != nil <- normalize_mac(device["mac"]) do
      [
        %Observation{
          provider: @provider,
          source: :omada_device,
          kind: :device,
          reference: device["mac"],
          role: role,
          mac: mac,
          ip: normalize_ip(device["ip"]),
          description: blank_to_nil(device["name"]),
          uplink_mac: normalize_mac(device["uplinkDeviceMac"]),
          uplink_name: blank_to_nil(device["uplinkDeviceName"]),
          uplink_port: port(device["uplinkDevicePort"]),
          wireless: false
        }
      ]
    else
      _not_a_network_device -> []
    end
  end

  defp device(_device), do: []

  defp role(type) when is_binary(type) do
    Enum.find_value(@role_by_type, fn {prefix, role} ->
      if String.starts_with?(type, prefix), do: role
    end)
  end

  defp role(_type), do: nil

  @doc "Connected clients become device observations with their current uplink."
  @spec clients(any()) :: [Observation.t()]
  def clients(clients) when is_list(clients), do: Enum.flat_map(clients, &client/1)
  def clients(_clients), do: []

  defp client(%{} = client) do
    case normalize_mac(client["mac"]) do
      nil -> []
      mac -> [client_observation(client, mac)]
    end
  end

  defp client(_client), do: []

  defp client_observation(client, mac) do
    {uplink_mac, uplink_name} = uplink(client)
    wireless = client["wireless"] == true

    %Observation{
      provider: @provider,
      source: :omada_client,
      kind: :device,
      reference: client["mac"],
      mac: mac,
      ip: normalize_ip(client["ip"]),
      hostname: hostname(client["hostName"]),
      description: name(client["name"]),
      wireless: wireless,
      uplink_mac: normalize_mac(uplink_mac),
      uplink_name: blank_to_nil(uplink_name),
      uplink_port: if(wireless, do: nil, else: port(client["port"])),
      ssid: blank_to_nil(client["ssid"]),
      locked_to_ap: locked_to_ap(client),
      device_type: blank_to_nil(client["deviceType"]),
      device_kind: DeviceTypes.to_kind([client["deviceType"], client["deviceCategory"]]),
      vendor: blank_to_nil(client["vendor"]),
      model: blank_to_nil(client["model"])
    }
  end

  defp uplink(%{"wireless" => true} = client), do: {client["apMac"], client["apName"]}

  defp uplink(%{"switchMac" => mac} = client) when is_binary(mac) and mac != "",
    do: {mac, client["switchName"]}

  defp uplink(client), do: {client["gatewayMac"], client["gatewayName"]}

  defp locked_to_ap(%{"clientLockToApSetting" => %{"enable" => enabled}})
       when is_boolean(enabled), do: enabled

  defp locked_to_ap(_client), do: nil

  defp name(name) do
    case blank_to_nil(name) do
      nil -> nil
      name -> if MacAddress.normalize(name) == :error, do: name
    end
  end

  defp hostname(name) when is_binary(name) do
    hostname = String.downcase(name)
    if Interface.valid_dns_name?(hostname), do: hostname
  end

  defp hostname(_name), do: nil

  defp port(port) when is_integer(port), do: Integer.to_string(port)
  defp port(port) when is_binary(port) and port != "", do: port
  defp port(_port), do: nil

  defp normalize_mac(value) do
    case MacAddress.normalize(value) do
      {:ok, mac} -> mac
      :error -> nil
    end
  end

  defp normalize_ip(value) do
    case IpAddress.parse(value) do
      {:ok, address} -> IpAddress.format(address)
      :error -> nil
    end
  end

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil
end
