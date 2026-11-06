defmodule Belgo.Fixtures.AdguardClient do
  @moduledoc """
  AdGuard Home client returning Springfield fixture documents. Writes are sent to the
  calling process as `{:adguard_request, method, path, body}` and succeed with an
  empty body. The `broken.example` instance fails every call.
  """

  @behaviour Belgo.Providers.Adguard.Client

  @impl Belgo.Providers.Adguard.Client
  def get(%{url: "https://broken.example"}, path), do: {:error, {:http_status, path, 401, ""}}
  def get(_config, "/control/rewrite/list"), do: {:ok, rewrites()}
  def get(_config, "/control/clients"), do: {:ok, clients()}

  @impl Belgo.Providers.Adguard.Client
  def request(_config, method, path, body) do
    send(self(), {:adguard_request, method, path, body})
    {:ok, ""}
  end

  @doc """
  Rewrites: Moe's tavern (unknown, joins Moe's reservation by IP), Smithers'
  assistant (matching), a stale Smithers answer, a CNAME and a disabled one.
  """
  def rewrites do
    [
      %{"domain" => "duff.springfield.lan", "answer" => "10.0.0.50", "enabled" => true},
      %{"domain" => "assistant.springfield.lan", "answer" => "10.0.0.11", "enabled" => true},
      %{"domain" => "smithers.springfield.lan", "answer" => "10.0.0.12", "enabled" => true},
      %{
        "domain" => "plow-king.springfield.lan",
        "answer" => "mr-plow.springfield.lan",
        "enabled" => true
      },
      %{"domain" => "old.springfield.lan", "answer" => "10.0.0.77", "enabled" => false}
    ]
  end

  @doc """
  Clients document. Persistent: Lisa's laptop (known MAC, old name and a ClientID),
  Ralph's tablet (unknown), and Milhouse's phone holding the IP of the living room
  TV whose MAC is another client. Automatic
  clients: Bart's console (seen by rDNS) and a noname ARP entry.
  """
  def clients do
    %{
      "clients" => [
        %{
          "name" => "Lisa's computer",
          "ids" => ["02-00-00-00-00-30", "lisa-doh"],
          "tags" => ["device_pc", "user_child"],
          "use_global_settings" => false,
          "filtering_enabled" => true,
          "parental_enabled" => true,
          "blocked_services" => ["tiktok"],
          "upstreams" => ["9.9.9.9"]
        },
        %{
          "name" => "Ralph Tablet",
          "ids" => ["02:00:00:00:09:09", "10.0.0.90", "10.0.0.91"],
          "tags" => []
        },
        %{"name" => "Milhouse Phone", "ids" => ["10.0.0.20"], "tags" => ["device_phone"]},
        %{"name" => "Living Room TV", "ids" => ["02:00:00:00:00:20"], "tags" => ["device_tv"]}
      ],
      "auto_clients" => [
        %{"ip" => "10.0.0.66", "name" => "bart-console.springfield.lan", "source" => "rDNS"},
        %{"ip" => "10.0.0.67", "name" => "", "source" => "ARP"}
      ],
      "supported_tags" =>
        ~w(device_gameconsole device_laptop device_other device_pc device_phone device_tv os_linux user_child)
    }
  end
end
