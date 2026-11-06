defmodule Belgo.Config do
  @moduledoc """
  Global settings of Belgo, read from `config.yaml` next to the inventory files. A
  missing file or key means the default value.

      version: 1
      ping:
        cache_duration: 15m   # a result is reused for that long
        timeout: 2s           # how long to wait for an answer

  Read when needed, so edits apply without restart.
  """

  alias Belgo.Config.Ping
  alias Belgo.Duration

  @file_name "config.yaml"
  @format_version 1
  @minimum_cache_duration_milliseconds 0
  @minimum_timeout_milliseconds 1

  defstruct ping: %Ping{}

  @type t :: %__MODULE__{ping: Ping.t()}

  @doc "Reads and validates `config.yaml` from the inventory directory."
  @spec load(Path.t()) :: {:ok, t()} | {:error, [String.t()]}
  def load(directory) do
    path = Path.join(directory, @file_name)

    if File.exists?(path) do
      case YamlElixir.read_from_file(path) do
        {:ok, document} -> parse(document)
        {:error, error} -> {:error, ["#{@file_name}: #{Exception.message(error)}"]}
      end
    else
      {:ok, %__MODULE__{}}
    end
  end

  @doc "Validates a parsed `config.yaml` document."
  @spec parse(any()) :: {:ok, t()} | {:error, [String.t()]}
  def parse(%{"version" => @format_version} = document) do
    with {:ok, ping} <- parse_ping(Map.get(document, "ping") || %{}) do
      {:ok, %__MODULE__{ping: ping}}
    end
  end

  def parse(nil), do: {:ok, %__MODULE__{}}
  def parse(_document), do: {:error, ["#{@file_name}: expected `version: #{@format_version}`"]}

  defp parse_ping(options) when is_map(options) do
    defaults = %Ping{}

    results = [
      cache_duration:
        duration(
          options,
          "cache_duration",
          defaults.cache_duration,
          @minimum_cache_duration_milliseconds
        ),
      timeout: duration(options, "timeout", defaults.timeout, @minimum_timeout_milliseconds)
    ]

    case for({_key, {:error, message}} <- results, do: message) do
      [] -> {:ok, struct!(Ping, for({key, {:ok, value}} <- results, do: {key, value}))}
      messages -> {:error, messages}
    end
  end

  defp parse_ping(_options), do: {:error, ["#{@file_name}: ping must be a map"]}

  defp duration(options, key, default, minimum) do
    case Map.fetch(options, key) do
      :error ->
        {:ok, default}

      {:ok, value} ->
        case Duration.parse(value) do
          {:ok, milliseconds} when milliseconds >= minimum -> {:ok, milliseconds}
          _invalid -> {:error, "#{@file_name}: ping.#{key} must look like 30s, 15m or 1h"}
        end
    end
  end
end
