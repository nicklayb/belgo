defmodule Belgo.Discovery do
  @moduledoc """
  Suggestions from external providers: records they know and the inventory does not
  (to claim or ignore), and divergences on records the inventory already has.
  """

  alias Belgo.Discovery.Correlation.DiscoveredDevice
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
  def push_device(device_id, server \\ Server), do: GenServer.cast(server, {:push, device_id})

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
end
