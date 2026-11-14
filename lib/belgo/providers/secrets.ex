defmodule Belgo.Providers.Secrets do
  @moduledoc """
  Resolves provider secrets, which never live in the data files.

  A secret `NAME` is read from the `NAME` environment variable, or from the file
  whose path is in `NAME_FILE` (Docker / Kubernetes secrets).
  """

  @file_suffix "_FILE"

  @type environment :: %{String.t() => String.t()}
  @type file_reader :: (Path.t() -> {:ok, binary()} | {:error, File.posix()})

  @doc "Reads a secret from the environment, trimming files' trailing newline."
  @spec fetch(String.t(), environment(), file_reader()) ::
          {:ok, String.t()} | {:error, String.t()}
  def fetch(name, environment \\ System.get_env(), read_file \\ &File.read/1) do
    case {Map.get(environment, name), Map.get(environment, name <> @file_suffix)} do
      {value, _path} when is_binary(value) and value != "" ->
        {:ok, value}

      {_value, path} when is_binary(path) and path != "" ->
        read_secret_file(name, path, read_file)

      _missing ->
        {:error, "missing secret: set #{name} or #{name}#{@file_suffix}"}
    end
  end

  @doc "Like `fetch/3`, but `{:ok, nil}` when neither `NAME` nor `NAME_FILE` is set."
  @spec fetch_optional(String.t(), environment(), file_reader()) ::
          {:ok, String.t() | nil} | {:error, String.t()}
  def fetch_optional(name, environment \\ System.get_env(), read_file \\ &File.read/1) do
    if Enum.any?([name, name <> @file_suffix], &(Map.get(environment, &1) not in [nil, ""])),
      do: fetch(name, environment, read_file),
      else: {:ok, nil}
  end

  defp read_secret_file(name, path, read_file) do
    case read_file.(path) do
      {:ok, content} -> {:ok, String.trim(content)}
      {:error, reason} -> {:error, "unable to read #{name}#{@file_suffix} (#{path}): #{reason}"}
    end
  end
end
