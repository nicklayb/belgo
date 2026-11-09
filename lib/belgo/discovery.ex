defmodule Belgo.Discovery do
  @moduledoc """
  Suggestions from external providers: records they know and the inventory does not
  (to claim or ignore), and divergences on records the inventory already has.
  """

  alias Belgo.Discovery.Correlation.DiscoveredDevice
  alias Belgo.Discovery.DnsNames.DiscoveredDnsName
  alias Belgo.Discovery.Server
  alias Belgo.Discovery.State
  alias Belgo.Discovery.UseCase

  @doc "Returns the current discovery state."
  @spec state(GenServer.server()) :: State.t()
  def state(server \\ Server), do: GenServer.call(server, :state)

  @doc "Pulls every enabled provider again, in the background."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ Server), do: GenServer.cast(server, :refresh)

  @doc "Pulls one provider again (e.g. after a failure), in the background."
  @spec refresh_provider(atom(), GenServer.server()) :: :ok
  def refresh_provider(provider_key, server \\ Server) when is_atom(provider_key),
    do: GenServer.cast(server, {:refresh, provider_key})

  @doc """
  Pushes the records of a device (DHCP reservations, DNS names) to the providers, in
  the background, to the providers in `write` mode.
  """
  @spec push_device(String.t(), GenServer.server()) :: :ok
  def push_device(device_id, server \\ Server),
    do: GenServer.cast(server, {:push, {:devices, device_id}})

  @doc """
  Deletes, in the providers in write mode, what they hold for MAC addresses removed
  from the inventory (Kea reservations), in the background. `owner` is the changed
  `{collection, id}`, used in logs; addresses back in the inventory meanwhile are kept.
  """
  @spec release_mac_addresses({atom(), String.t()}, [String.t()], GenServer.server()) :: :ok
  def release_mac_addresses(owner, mac_addresses, server \\ Server)

  def release_mac_addresses(_owner, [], _server), do: :ok

  def release_mac_addresses({_collection, _id} = owner, mac_addresses, server),
    do: GenServer.cast(server, {:release, owner, mac_addresses})

  @doc "Pushes the DNS names of a virtual IP to the providers in write mode, in the background."
  @spec push_virtual_ip(String.t(), GenServer.server()) :: :ok
  def push_virtual_ip(virtual_ip_id, server \\ Server),
    do: GenServer.cast(server, {:push, {:virtual_ips, virtual_ip_id}})

  @doc "Subscribes to `{:discovery_changed, state}` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Belgo.PubSub, Server.default_topic())

  @doc "Adds the MAC addresses of a discovered device to the denylist."
  @spec ignore(DiscoveredDevice.t(), Keyword.t()) ::
          {:ok, list()} | {:error, any()} | {:error, any(), any(), map()}
  def ignore(%DiscoveredDevice{} = discovered, options) do
    Belgo.UseCase.execute(UseCase.IgnoreDevice, discovered, options)
  end

  @doc "Removes the MAC addresses of a discovered device from the denylist."
  @spec stop_ignoring(DiscoveredDevice.t(), Keyword.t()) ::
          {:ok, list()} | {:error, any()} | {:error, any(), any(), map()}
  def stop_ignoring(%DiscoveredDevice{} = discovered, options) do
    Belgo.UseCase.execute(UseCase.StopIgnoringDevice, discovered, options)
  end

  @doc "Adds the interfaces of a discovered device to an existing device."
  @spec attach(DiscoveredDevice.t(), String.t(), Keyword.t()) ::
          {:ok, Belgo.Inventory.Device.t()} | {:error, any()} | {:error, any(), any(), map()}
  def attach(%DiscoveredDevice{} = discovered, device_id, options) do
    Belgo.UseCase.execute(UseCase.AttachToDevice, {discovered, device_id}, options)
  end

  @doc """
  Adds a discovered DNS name to a device interface (`{:devices, device_id, position}`)
  or to a virtual IP (`{:virtual_ips, virtual_ip_id}`).
  """
  @spec claim_dns_name(
          DiscoveredDnsName.t(),
          {:devices, String.t(), non_neg_integer()} | {:virtual_ips, String.t()},
          Keyword.t()
        ) ::
          {:ok, Belgo.Inventory.Device.t() | Belgo.Inventory.VirtualIp.t()}
          | {:error, any()}
          | {:error, any(), any(), map()}
  def claim_dns_name(%DiscoveredDnsName{} = discovered, target, options),
    do: Belgo.UseCase.execute(UseCase.ClaimDnsName, {discovered, target}, options)
end
