defmodule Belgo.Discovery.Observation do
  @moduledoc """
  One fact reported by a provider, e.g. an OPNsense DHCP reservation or a DNS host
  override. Observations are never persisted: they are recomputed by each discovery.

  `kind` is `:device`, `:network` or `:location`; `source` names the provider's record
  type. Locations carry a `name`, a `reference` and the `parent_reference` of the
  location they belong to (a Home Assistant area on its floor), floors a `level`.
  `identity` links observations of the same machine having neither MAC nor IP in
  common (e.g. the IP addresses of a gateway). `role` marks network devices; `uplink_*`
  tell where a device is connected right now (switch port or access point).
  `device_kind` is the Belgo kind a provider's client type maps to, `vendor` and
  `model` what the provider recognised (Omada clients).
  """

  @enforce_keys [:provider, :source, :kind]
  defstruct [
    :provider,
    :source,
    :kind,
    :reference,
    :mac,
    :ip,
    :hostname,
    :domain,
    :cidr,
    :gateway,
    :dhcp_start,
    :dhcp_end,
    :description,
    :identity,
    :role,
    :uplink_mac,
    :uplink_name,
    :uplink_port,
    :wireless,
    :ssid,
    :locked_to_ap,
    :name,
    :parent_reference,
    :level,
    :device_type,
    :device_kind,
    :vendor,
    :model
  ]

  @type t :: %__MODULE__{
          provider: atom(),
          source: atom(),
          kind: :device | :network | :location,
          reference: String.t() | nil,
          mac: String.t() | nil,
          ip: String.t() | nil,
          hostname: String.t() | nil,
          domain: String.t() | nil,
          cidr: String.t() | nil,
          gateway: String.t() | nil,
          dhcp_start: String.t() | nil,
          dhcp_end: String.t() | nil,
          description: String.t() | nil,
          identity: String.t() | nil,
          role: :gateway | :switch | :access_point | nil,
          uplink_mac: String.t() | nil,
          uplink_name: String.t() | nil,
          uplink_port: String.t() | nil,
          wireless: boolean() | nil,
          ssid: String.t() | nil,
          locked_to_ap: boolean() | nil,
          name: String.t() | nil,
          parent_reference: String.t() | nil,
          level: integer() | nil,
          device_type: String.t() | nil,
          device_kind: atom() | nil,
          vendor: String.t() | nil,
          model: String.t() | nil
        }

  @dns_record_sources [:unbound_host_override, :adguard_rewrite]

  @doc "Returns `true` for observations of a DNS name resolving to an address."
  @spec dns_record?(t()) :: boolean()
  def dns_record?(%__MODULE__{source: source}), do: source in @dns_record_sources

  @doc """
  Fully qualified name of a DNS observation, or its hostname. An Unbound host
  override without host names the domain itself (`k8s.home.arpa`).
  """
  @spec fqdn(t()) :: String.t() | nil
  def fqdn(%__MODULE__{hostname: nil, domain: domain}), do: domain
  def fqdn(%__MODULE__{hostname: hostname, domain: nil}), do: hostname
  def fqdn(%__MODULE__{hostname: hostname, domain: domain}), do: "#{hostname}.#{domain}"
end
