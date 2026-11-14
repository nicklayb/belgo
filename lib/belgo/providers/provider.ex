defmodule Belgo.Providers.Provider do
  @moduledoc """
  Behaviour of an external system Belgo discovers records from (and later pushes to).

  Providers are optional: only those configured in `providers.yaml` are used.
  """

  alias Belgo.Discovery.Report
  alias Belgo.Providers.Secrets
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.PushReport

  @type config :: struct()

  @doc "Name of the provider in `providers.yaml` and in logs."
  @callback key() :: atom()

  @doc "Human readable name."
  @callback label() :: String.t()

  @doc "Builds the provider configuration from its public options and the secrets."
  @callback parse_config(options :: map(), Secrets.environment()) ::
              {:ok, config()} | {:error, [String.t()]}

  @doc "Reads what the provider knows. Side effects only happen here."
  @callback discover(config()) :: {:ok, Report.t()} | {:error, any()}

  @doc """
  Writes a desired state to the provider: creates missing entries, updates differing
  ones, never deletes (see `c:release/2`). Only called for providers in `write` mode.
  """
  @callback push(config(), DesiredState.t()) :: {:ok, PushReport.t()} | {:error, any()}

  @doc """
  Deletes what the provider holds for MAC addresses removed from the inventory
  (deleted device or interface, changed MAC). The only destructive write; only called
  for providers in `write` mode.
  """
  @callback release(config(), mac_addresses :: [String.t()]) ::
              {:ok, PushReport.t()} | {:error, any()}

  @doc """
  Returns `true` when devices are woken through this provider (`wake/3`), `false`
  when its configuration turns wake-on-LAN off.
  """
  @callback wake_on_lan?(config()) :: boolean()

  @doc "Wakes the device with `mac`, on the network holding `address`."
  @callback wake(config(), mac :: String.t(), address :: String.t()) :: :ok | {:error, any()}

  @doc """
  Asks the controller to reconnect a wireless client (`reference` being the client as
  the provider identifies it, `Observation.reference`). Only called for providers in
  `write` mode, on a user action.
  """
  @callback reconnect_client(config(), reference :: String.t()) :: :ok | {:error, any()}

  @optional_callbacks push: 2, release: 2, wake_on_lan?: 1, wake: 3, reconnect_client: 2
end
