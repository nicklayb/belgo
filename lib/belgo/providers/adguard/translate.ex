defmodule Belgo.Providers.Adguard.Translate do
  @moduledoc "Turns AdGuard Home API documents into observations. Pure functions only."

  alias Belgo.Discovery.Observation
  alias Belgo.Inventory.Interface
  alias Belgo.Network.IpAddress
  alias Belgo.Network.MacAddress

  @provider :adguard

  @doc """
  Enabled rewrites answering an IP address become device observations; CNAME answers
  are left out since they do not point to a machine.
  """
  @spec rewrites(any()) :: [Observation.t()]
  def rewrites(rows) when is_list(rows) do
    for %{"domain" => domain, "answer" => answer} = row <- rows,
        Map.get(row, "enabled", true),
        ip = normalize_ip(answer),
        ip != nil do
      {hostname, zone} = split_domain(domain)

      %Observation{
        provider: @provider,
        source: :adguard_rewrite,
        kind: :device,
        reference: "#{domain} #{answer}",
        ip: ip,
        hostname: hostname,
        domain: zone
      }
    end
  end

  def rewrites(_body), do: []

  @doc """
  Persistent clients become device observations named after the client. Each MAC is
  paired with the first IP so the observation links both; extra IPs get their own.
  Automatic clients (ARP, rDNS, DHCP…) become IP observations with their hostname.
  """
  @spec clients(any()) :: [Observation.t()]
  def clients(%{} = document) do
    persistent =
      document
      |> Map.get("clients")
      |> List.wrap()
      |> Enum.flat_map(&client/1)

    automatic =
      document
      |> Map.get("auto_clients")
      |> List.wrap()
      |> Enum.flat_map(&auto_client/1)

    persistent ++ automatic
  end

  def clients(_body), do: []

  defp auto_client(%{"ip" => ip} = auto_client) do
    case normalize_ip(ip) do
      nil ->
        []

      address ->
        {hostname, zone} = auto_client_name(Map.get(auto_client, "name"))

        [
          %Observation{
            provider: @provider,
            source: :adguard_auto_client,
            kind: :device,
            reference: address,
            ip: address,
            hostname: hostname,
            domain: zone,
            description: Map.get(auto_client, "source")
          }
        ]
    end
  end

  defp auto_client(_auto_client), do: []

  defp auto_client_name(name) when is_binary(name) and name != "" do
    if Interface.valid_dns_name?(String.downcase(name)), do: split_domain(name), else: {nil, nil}
  end

  defp auto_client_name(_name), do: {nil, nil}

  defp client(%{"name" => name, "ids" => ids}) when is_list(ids) do
    macs = for id <- ids, {:ok, mac} <- [MacAddress.normalize(id)], do: mac
    ips = for id <- ids, ip = normalize_ip(id), ip != nil, do: ip

    pairs =
      case {macs, ips} do
        {[], ips} ->
          Enum.map(ips, &{nil, &1})

        {macs, []} ->
          Enum.map(macs, &{&1, nil})

        {macs, [first_ip | other_ips]} ->
          Enum.map(macs, &{&1, first_ip}) ++ Enum.map(other_ips, &{hd(macs), &1})
      end

    for {mac, ip} <- pairs do
      %Observation{
        provider: @provider,
        source: :adguard_client,
        kind: :device,
        reference: name,
        mac: mac,
        ip: ip,
        description: name
      }
    end
  end

  defp client(_client), do: []

  defp split_domain(domain) do
    case String.split(String.downcase(domain), ".", parts: 2) do
      [hostname, zone] -> {hostname, zone}
      [hostname] -> {hostname, nil}
    end
  end

  defp normalize_ip(value) do
    case IpAddress.parse(value) do
      {:ok, address} -> IpAddress.format(address)
      :error -> nil
    end
  end
end
