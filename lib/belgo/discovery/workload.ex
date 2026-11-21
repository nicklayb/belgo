defmodule Belgo.Discovery.Workload do
  @moduledoc """
  Something running on a host right now, as reported by a provider: a Kubernetes
  pod, a Docker container, a Proxmox VM or LXC container. Live data only, rebuilt on
  each pull and never persisted (like `Belgo.Discovery.Uplink`).

  `host` tells which machine runs it, as the provider names it; the correlation
  resolves it to an inventory device (`Belgo.Discovery.Workloads`). `macs` are the
  guest's own MAC addresses (Proxmox guests), joining it to an inventory device.
  `group` gathers workloads: the application of a pod (`app.kubernetes.io/instance`
  label when exported, else its owning workload), the Compose project of a container.
  `host_id` (the inventory device running it) and `device_id` (the inventory device
  it is, for guests) are set by the correlation.
  """

  defmodule HostReference do
    @moduledoc """
    A host as a provider names it: its name (Kubernetes node, Proxmox node, scrape
    target host), the addresses it reports, and `device_id` when the provider
    configuration names the inventory device explicitly.
    """
    @enforce_keys [:name]
    defstruct [:name, :device_id, ips: [], macs: []]

    @type t :: %__MODULE__{
            name: String.t(),
            device_id: String.t() | nil,
            ips: [String.t()],
            macs: [String.t()]
          }
  end

  @enforce_keys [:provider, :source, :kind, :name, :host]
  defstruct [
    :provider,
    :source,
    :kind,
    :name,
    :host,
    :reference,
    :namespace,
    :group,
    :image,
    :status,
    :host_id,
    :device_id,
    macs: []
  ]

  @type kind :: :pod | :container | :virtual_machine | :lxc
  @type t :: %__MODULE__{
          provider: atom(),
          source: atom(),
          kind: kind(),
          name: String.t(),
          host: HostReference.t(),
          reference: String.t() | nil,
          namespace: String.t() | nil,
          group: String.t() | nil,
          image: String.t() | nil,
          status: String.t() | nil,
          host_id: String.t() | nil,
          device_id: String.t() | nil,
          macs: [String.t()]
        }

  @guest_kinds [:virtual_machine, :lxc]

  @doc "Returns `true` for virtual machines and LXC containers (Proxmox guests)."
  @spec guest?(t()) :: boolean()
  def guest?(%__MODULE__{kind: kind}), do: kind in @guest_kinds
end
