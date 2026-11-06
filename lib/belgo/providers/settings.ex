defmodule Belgo.Providers.Settings do
  @moduledoc """
  Which providers are used, how, and their public options, read from
  `providers.yaml` next to the inventory files. A missing file means no provider.

      version: 1
      providers:
        opnsense:
          mode: write
          url: https://opnsense.home.lan
          verify_tls: false

  `mode` applies to every provider:

    * `disabled` – kept in the file but not used
    * `read` (default) – discovery only, nothing is ever written
    * `write` – discovery, and saved devices are pushed to the provider

  `interval` (e.g. `30s`, `5m`, `1h`, or seconds) pulls the provider periodically, at
  least every 10 seconds; without it, providers are pulled at boot and on demand.

  Secrets are never read from this file (see `Belgo.Providers.Secrets`).
  """

  alias Belgo.Providers.Adguard
  alias Belgo.Providers.HomeAssistant
  alias Belgo.Providers.Omada
  alias Belgo.Providers.Opnsense
  alias Belgo.Providers.Secrets

  @file_name "providers.yaml"
  @format_version 1
  @provider_modules [Adguard, HomeAssistant, Omada, Opnsense]
  @mode_key "mode"
  @interval_key "interval"
  @minimum_interval_milliseconds 10_000
  @default_mode "read"
  @mode_by_name %{"disabled" => :disabled, "read" => :read, "write" => :write}

  defmodule Configured do
    @moduledoc "A provider in use: its module, its mode and its parsed configuration."
    @enforce_keys [:module, :mode, :config]
    defstruct [:module, :mode, :config, :interval]

    @type mode :: :read | :write
    @type t :: %__MODULE__{
            module: module(),
            mode: mode(),
            config: struct(),
            interval: pos_integer() | nil
          }
  end

  defstruct configs: []

  @type t :: %__MODULE__{configs: [Configured.t()]}

  @doc "Lists the supported provider modules."
  @spec provider_modules() :: [module()]
  def provider_modules, do: @provider_modules

  @doc "Reads and validates `providers.yaml` from the inventory directory."
  @spec load(Path.t(), Secrets.environment()) :: {:ok, t()} | {:error, [String.t()]}
  def load(directory, environment \\ System.get_env()) do
    path = Path.join(directory, @file_name)

    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, document} -> parse(document, environment)
        {:error, error} -> {:error, ["#{@file_name}: #{Exception.message(error)}"]}
      end
    else
      {:ok, %__MODULE__{}}
    end
  end

  @doc "Validates a parsed `providers.yaml` document."
  @spec parse(any(), Secrets.environment()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(%{"version" => @format_version} = document, environment) do
    options_by_provider = Map.get(document, "providers") || %{}

    {configs, errors} =
      Enum.reduce(options_by_provider, {[], []}, fn {name, options}, {configs, errors} ->
        case parse_provider(name, options || %{}, environment) do
          {:ok, nil} ->
            {configs, errors}

          {:ok, configured} ->
            {[configured | configs], errors}

          {:error, messages} ->
            {configs, errors ++ Enum.map(messages, &"#{@file_name} (#{name}): #{&1}")}
        end
      end)

    if errors == [],
      do: {:ok, %__MODULE__{configs: Enum.sort_by(configs, & &1.module.key())}},
      else: {:error, errors}
  end

  def parse(_document, _environment),
    do: {:error, ["#{@file_name}: expected `version: #{@format_version}`"]}

  @doc "Lists the providers in `write` mode."
  @spec writable(t()) :: [Configured.t()]
  def writable(%__MODULE__{configs: configs}), do: Enum.filter(configs, &(&1.mode == :write))

  defp parse_provider(name, options, environment) do
    with {:ok, module} <- find_module(name),
         {:ok, mode} <- parse_mode(module, Map.get(options, @mode_key, @default_mode)),
         {:ok, interval} <- parse_interval(Map.get(options, @interval_key)) do
      configure(
        module,
        mode,
        interval,
        Map.drop(options, [@mode_key, @interval_key]),
        environment
      )
    end
  end

  defp configure(_module, :disabled, _interval, _options, _environment), do: {:ok, nil}

  defp configure(module, mode, interval, options, environment) do
    with {:ok, config} <- module.parse_config(options, environment) do
      {:ok, %Configured{module: module, mode: mode, config: config, interval: interval}}
    end
  end

  defp parse_interval(nil), do: {:ok, nil}

  defp parse_interval(value) do
    case Belgo.Duration.parse(value) do
      {:ok, milliseconds} when milliseconds >= @minimum_interval_milliseconds ->
        {:ok, milliseconds}

      {:ok, _too_short} ->
        {:error, ["interval must be at least 10s"]}

      :error ->
        {:error, ["interval must look like 30s, 5m or 1h"]}
    end
  end

  defp parse_mode(module, name) do
    case Map.fetch(@mode_by_name, name) do
      {:ok, :write} ->
        if Code.ensure_loaded?(module) and function_exported?(module, :push, 2),
          do: {:ok, :write},
          else: {:error, ["mode write is not supported by this provider"]}

      {:ok, mode} ->
        {:ok, mode}

      :error ->
        {:error, ["mode must be disabled, read or write"]}
    end
  end

  defp find_module(name) do
    case Enum.find(@provider_modules, &(Atom.to_string(&1.key()) == name)) do
      nil -> {:error, ["unknown provider"]}
      module -> {:ok, module}
    end
  end
end
