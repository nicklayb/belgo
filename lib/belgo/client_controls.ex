defmodule Belgo.ClientControls do
  @moduledoc """
  Actions on a device through a controller that sees it as a client (Omada: reconnect
  a Wi-Fi client).

  `clients/2` is pure: the client observations (from the last discovery) of the
  device's MAC addresses. `reconnect/2` re-reads `providers.yaml` and calls the
  provider's `c:Belgo.Providers.Provider.reconnect_client/2`, only for providers in
  `write` mode. Logs `debug` on start, `info` on success, `error` on failure.
  """

  alias Belgo.Discovery.Observation
  alias Belgo.Inventory.Device
  alias Belgo.Providers.Settings
  alias Belgo.Providers.Settings.Configured

  require Logger

  @client_sources [:omada_client]

  @type reconnect_error ::
          :not_wireless | :not_writable | :unsupported | {:settings, [String.t()]} | term()

  @doc "Client observations whose MAC belongs to an interface of the device."
  @spec clients([Observation.t()], Device.t()) :: [Observation.t()]
  def clients(observations, %Device{} = device) do
    mac_addresses =
      for %{mac: mac} <- device.interfaces, mac != nil, into: MapSet.new(), do: mac

    observations
    |> Enum.filter(&(&1.source in @client_sources and MapSet.member?(mac_addresses, &1.mac)))
    |> Enum.uniq_by(&{&1.provider, &1.mac})
    |> Enum.sort_by(&{&1.provider, &1.mac})
  end

  @doc "Returns `true` when the controller can reconnect the client (wireless only)."
  @spec reconnectable?(Observation.t()) :: boolean()
  def reconnectable?(%Observation{wireless: wireless}), do: wireless == true

  @doc """
  Asks the provider of the client to reconnect it. Options `:directory` and
  `:environment` are passed to `Belgo.Providers.Settings.current/1`.
  """
  @spec reconnect(Observation.t(), Keyword.t()) :: :ok | {:error, reconnect_error()}
  def reconnect(%Observation{} = client, options \\ []) do
    log_prefix = "[client_controls] [#{client.provider}] [#{client.mac}]"

    with :ok <- check_reconnectable(client),
         {:ok, %Configured{module: module, config: config}} <-
           writable_provider(client.provider, options) do
      Logger.debug("#{log_prefix} reconnecting")
      log_result(module.reconnect_client(config, client.reference), log_prefix)
    end
  end

  defp check_reconnectable(client),
    do: if(reconnectable?(client), do: :ok, else: {:error, :not_wireless})

  defp writable_provider(provider_key, options) do
    with {:ok, settings} <- current_settings(options) do
      case Enum.find(settings.configs, &(&1.module.key() == provider_key)) do
        nil -> {:error, :not_writable}
        %Configured{mode: :write} = configured -> supported(configured)
        %Configured{} -> {:error, :not_writable}
      end
    end
  end

  defp current_settings(options) do
    case Settings.current(options) do
      {:ok, settings} -> {:ok, settings}
      {:error, messages} -> {:error, {:settings, messages}}
    end
  end

  defp supported(%Configured{module: module} = configured) do
    if Code.ensure_loaded?(module) and function_exported?(module, :reconnect_client, 2),
      do: {:ok, configured},
      else: {:error, :unsupported}
  end

  defp log_result(:ok, log_prefix) do
    Logger.info("#{log_prefix} reconnect requested")
    :ok
  end

  defp log_result({:error, reason} = error, log_prefix) do
    Logger.error("#{log_prefix} reconnect failed: #{inspect(reason)}")
    error
  end
end
