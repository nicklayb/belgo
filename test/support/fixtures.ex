defmodule Belgo.Fixtures do
  @moduledoc "Deterministic inventory records set in Springfield."

  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Interface
  alias Belgo.Inventory.Location
  alias Belgo.Inventory.Network
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.VirtualIp

  @doc "A location."
  def location(attributes \\ []) do
    struct!(
      %Location{id: "evergreen-terrace", name: "742 Evergreen Terrace", kind: :site},
      attributes
    )
  end

  @doc "A virtual IP: the Kwik-E-Mart load balancer, answered for by Burns Node."
  def virtual_ip(attributes \\ []) do
    struct!(
      %VirtualIp{
        id: "kwik-e-mart",
        name: "Kwik-E-Mart",
        ip: "10.0.0.110",
        kind: :metallb,
        owner_id: "burns-node",
        dns_names: ["squishee", "apu.kwik-e-mart.lan"]
      },
      attributes
    )
  end

  @doc "The fixture snapshot with virtual IPs."
  def snapshot_with_virtual_ips(virtual_ips \\ [virtual_ip()]),
    do: %{snapshot() | virtual_ips: virtual_ips}

  @doc "A network."
  def network(attributes \\ []) do
    struct!(
      %Network{
        id: "springfield",
        name: "Springfield",
        cidr: "10.0.0.0/24",
        gateway: "10.0.0.1",
        domain: "springfield.lan"
      },
      attributes
    )
  end

  @doc "A device."
  def device(attributes \\ []) do
    struct!(%Device{id: "homer-pc", name: "Homer PC", kind: :workstation}, attributes)
  end

  @doc "An interface."
  def interface(attributes \\ []) do
    struct!(
      %Interface{
        name: "eth0",
        mac: "02:00:00:00:07:42",
        ip: "10.0.0.42",
        network_id: "springfield"
      },
      attributes
    )
  end

  @doc """
  A small but complete homelab: Homer's basement rack with the Power Plant gateway,
  the Plow King switch plugged into it, a Proxmox node
  (`burns-node`) running `smithers` (VM) which runs `itchy` (container),
  Lisa's laptop being portable and Bart's console left unplaced.
  """
  def snapshot do
    Snapshot.new(%{
      locations: [
        location(),
        location(id: "basement", name: "Basement", kind: :room, parent_id: "evergreen-terrace"),
        location(
          id: "living-room",
          name: "Living Room",
          kind: :room,
          parent_id: "evergreen-terrace"
        )
      ],
      networks: [network()],
      devices: [
        device(
          id: "power-plant",
          name: "Power Plant",
          network_role: :gateway,
          kind: :network,
          location_id: "basement",
          interfaces: [interface(mac: nil, ip: "10.0.0.1", assignment: :static, name: nil)]
        ),
        device(
          id: "plow-king",
          name: "Plow King",
          kind: :network,
          network_role: :switch,
          port_count: 8,
          poe: true,
          location_id: "basement",
          interfaces: [
            interface(
              mac: "02:00:00:00:00:02",
              ip: "10.0.0.2",
              switch_id: "power-plant",
              switch_port: "2"
            )
          ]
        ),
        device(
          id: "burns-node",
          name: "Burns Node",
          kind: :server,
          metadata: [
            %Belgo.Inventory.MetadataEntry{label: "Brand", value: "Excellent Computers"},
            %Belgo.Inventory.MetadataEntry{label: "Serial number", value: "SN-1895-MB"}
          ],
          location_id: "basement",
          platforms: [:proxmox],
          interfaces: [
            interface(
              mac: "02:00:00:00:00:10",
              ip: "10.0.0.10",
              switch_id: "plow-king",
              switch_port: "1"
            )
          ]
        ),
        device(
          id: "smithers",
          name: "Smithers",
          kind: :server,
          host_id: "burns-node",
          virtualization: :virtual_machine,
          platforms: [:docker],
          interfaces: [
            interface(
              mac: "02:00:00:00:00:11",
              ip: "10.0.0.11",
              dns_names: ["smithers", "assistant"]
            )
          ]
        ),
        device(
          id: "itchy",
          name: "Itchy",
          kind: :appliance,
          host_id: "smithers",
          virtualization: :container
        ),
        device(
          id: "tv-living-room",
          name: "TV Living Room",
          kind: :media,
          location_id: "living-room",
          interfaces: [interface(mac: "02:00:00:00:00:20", ip: "10.0.0.20", name: nil)]
        ),
        device(
          id: "lisa-laptop",
          name: "Lisa Laptop",
          kind: :laptop,
          portable: true,
          interfaces: [
            interface(mac: "02:00:00:00:00:30", ip: nil, assignment: :dynamic, network_id: nil)
          ]
        ),
        device(id: "bart-console", name: "Bart Console", kind: :media)
      ]
    })
  end
end
