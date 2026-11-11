defmodule Belgo.Fixtures.OpnsenseClient do
  @moduledoc """
  OPNsense client returning Springfield fixture rows. Posts are sent to the calling
  process as `{:opnsense_post, path, body}` and succeed. The `broken.example` instance
  fails every call; `rejecting.example` rejects Kea writes; `kea-only.example` denies
  Unbound (a token without its privileges).
  """

  @behaviour Belgo.Providers.Opnsense.Client

  @impl Belgo.Providers.Opnsense.Client
  def search(%{url: "https://broken.example"}, path), do: {:error, {:http_status, path, 401}}

  def search(%{url: "https://kea-only.example"}, "/api/unbound/" <> _rest = path),
    do: {:error, {:http_status, path, 403}}

  def search(_config, "/api/kea/dhcpv4/search_subnet"), do: {:ok, subnets()}
  def search(_config, "/api/kea/dhcpv4/search_reservation"), do: {:ok, reservations()}
  def search(_config, "/api/kea/leases4/search"), do: {:ok, leases()}
  def search(_config, "/api/unbound/settings/search_host_override"), do: {:ok, host_overrides()}
  def search(_config, "/api/interfaces/overview/interfaces_info"), do: {:ok, interfaces()}

  @impl Belgo.Providers.Opnsense.Client
  def post(%{url: "https://rejecting.example"}, "/api/kea/dhcpv4/" <> _command, _body) do
    {:ok,
     %{"result" => "failed", "validations" => %{"reservation.ip_address" => "already in use"}}}
  end

  def post(_config, "/api/wol/wol/set" = path, body) do
    send(self(), {:opnsense_post, path, body})
    {:ok, %{"status" => "OK"}}
  end

  def post(_config, path, body) do
    send(self(), {:opnsense_post, path, body})

    if String.ends_with?(path, "/reconfigure"),
      do: {:ok, %{"status" => "ok"}},
      else: {:ok, %{"result" => "saved", "uuid" => "new-uuid"}}
  end

  @doc "Interfaces overview: WAN, LAN on Springfield (with an alias), unassigned."
  def interfaces do
    [
      %{"identifier" => "wan", "addr4" => "203.0.113.2/24", "ipv4" => []},
      %{
        "identifier" => "lan",
        "addr4" => "10.0.0.1/24",
        "ipv4" => [%{"ipaddr" => "10.0.0.1/24"}, %{"ipaddr" => "10.0.7.1/24"}]
      },
      %{"identifier" => "", "addr4" => "10.0.5.1/24", "ipv4" => []}
    ]
  end

  @doc "Kea subnets: Springfield (known) and Shelbyville (new)."
  def subnets do
    [
      %{
        "uuid" => "subnet-springfield",
        "subnet" => "10.0.0.0/24",
        "description" => "Springfield",
        "option_data" => %{"routers" => "10.0.0.1", "domain_name" => "springfield.lan"}
      },
      %{
        "uuid" => "subnet-shelbyville",
        "subnet" => "10.0.5.0/24",
        "description" => "Shelbyville",
        "pools" => "10.0.5.100 - 10.0.5.199\n10.0.5.220-10.0.5.230",
        "option_data" => %{"routers" => "10.0.5.1", "domain_name" => ""}
      }
    ]
  end

  @doc "Kea reservations: Moe (unknown), Smithers (diverging), Burns (matching), Nelson (guest)."
  def reservations do
    [
      reservation("moe", "02:00:00:00:05:01", "10.0.0.50", "moe-pc", "Moe's PC"),
      reservation("smithers", "02-00-00-00-00-11", "10.0.0.99", "smithers", ""),
      reservation("burns", "02:00:00:00:00:10", "10.0.0.10", "burns-node", ""),
      reservation("nelson", "02:00:00:00:06:66", "10.0.0.66", "nelson-iphone", "Haw haw")
    ]
  end

  @doc """
  Kea leases: Moe (his reservation), Barney (dynamic, unknown, Shelbyville) and an
  expired-reclaimed lease of Duffman (state 2, dropped).
  """
  def leases do
    [
      lease("10.0.0.50", "02:00:00:00:05:01", "moe-pc", 0),
      lease("10.0.5.150", "02:00:00:00:07:01", "Barney-Laptop", 0),
      lease("10.0.5.151", "02:00:00:00:07:02", "duffman", 2)
    ]
  end

  @doc "Unbound host overrides joining reservations by IP address."
  def host_overrides do
    [
      host_override("moe-host", "moe-pc", "10.0.0.50"),
      host_override("moe-tavern", "tavern", "10.0.0.50"),
      host_override("assistant", "assistant", "10.0.0.11"),
      # Search rows give the record type label (measured on a real OPNsense).
      Map.put(host_override("smithers-wrong", "smithers", "10.0.0.10"), "rr", "A (IPv4 address)"),
      Map.put(host_override("mail", "mail", "10.0.0.25"), "rr", "MX (Mail server)")
    ]
  end

  defp reservation(uuid, mac, ip, hostname, description) do
    %{
      "uuid" => uuid,
      "subnet" => "subnet-springfield",
      "hw_address" => mac,
      "ip_address" => ip,
      "hostname" => hostname,
      "description" => description
    }
  end

  defp lease(address, mac, hostname, state) do
    %{
      "address" => address,
      "hwaddr" => mac,
      "hostname" => hostname,
      "state" => state,
      "lease_type" => "dynamic",
      "if_descr" => "LAN"
    }
  end

  defp host_override(uuid, hostname, ip) do
    %{
      "uuid" => uuid,
      "enabled" => "1",
      "hostname" => hostname,
      "domain" => "springfield.lan",
      "rr" => "A",
      "server" => ip,
      "description" => ""
    }
  end
end
