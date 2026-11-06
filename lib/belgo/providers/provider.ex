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
  ones, never deletes. Only called for providers in `write` mode.
  """
  @callback push(config(), DesiredState.t()) :: {:ok, PushReport.t()} | {:error, any()}

  @optional_callbacks push: 2
end
