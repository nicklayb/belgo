defmodule Belgo.Reachability do
  @moduledoc """
  Whether devices answer pings. Results live in memory only
  (`Belgo.Reachability.Server`) and are reused for `ping.cache_duration`
  (`config.yaml`, 15 minutes by default).
  """

  alias Belgo.Inventory.Device
  alias Belgo.Reachability.Server
  alias Belgo.Reachability.Status

  @doc """
  Returns the status of a device, pinging its addresses in the background when the
  last result is missing, stale, or for other addresses. `force: true` pings anyway
  (unless a check is already running).
  """
  @spec check(Device.t(), Keyword.t()) :: Status.t()
  def check(%Device{} = device, options \\ []) do
    GenServer.call(
      Keyword.get(options, :server, Server),
      {:check, device.id, Device.ip_addresses(device), Keyword.get(options, :force, false)}
    )
  end

  @doc "Returns the last known status of a device, without pinging."
  @spec status(String.t(), GenServer.server()) :: Status.t() | nil
  def status(device_id, server \\ Server), do: GenServer.call(server, {:status, device_id})

  @doc "PubSub topic of a device's status changes."
  @spec topic(String.t()) :: String.t()
  def topic(device_id), do: "reachability:#{device_id}"

  @doc "Subscribes to `{:reachability_changed, status}` messages of a device."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(device_id), do: Phoenix.PubSub.subscribe(Belgo.PubSub, topic(device_id))
end
