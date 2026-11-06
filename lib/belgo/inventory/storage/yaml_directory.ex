defmodule Belgo.Inventory.Storage.YamlDirectory do
  @moduledoc """
  Stores the inventory as one YAML file per collection in a directory
  (`locations.yaml`, `networks.yaml`, `devices.yaml`).

  Each file maps identifiers to entries, which makes identifiers unique by design:

      version: 1
      devices:
        hades:
          name: Hades
          kind: workstation

  Files are written atomically with sorted keys, so the output only changes when the
  data does: it diffs nicely in git.

  Options:

    * `:path` – directory holding the files (required)
  """

  @behaviour Belgo.Inventory.Storage

  alias Belgo.Inventory.Codec
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.Storage.DuplicateKeys

  @format_version 1
  @identifier_key "id"
  @header "Managed by Belgo. Hand edits are welcome, reload Belgo to apply them."

  @impl Belgo.Inventory.Storage
  def load(options) do
    directory = Keyword.fetch!(options, :path)

    {records_by_collection, errors} =
      Enum.reduce(Snapshot.collections(), {%{}, []}, fn collection,
                                                        {records_by_collection, errors} ->
        case load_collection(directory, collection) do
          {:ok, records} -> {Map.put(records_by_collection, collection, records), errors}
          {:error, collection_errors} -> {records_by_collection, errors ++ collection_errors}
        end
      end)

    if errors == [], do: {:ok, Snapshot.new(records_by_collection)}, else: {:error, errors}
  end

  @impl Belgo.Inventory.Storage
  def save(options, %Snapshot{} = snapshot, collection) do
    directory = Keyword.fetch!(options, :path)
    path = file_path(directory, collection)
    temporary_path = path <> ".tmp"

    document = %{
      "version" => @format_version,
      Atom.to_string(collection) => encode_records(Snapshot.list(snapshot, collection))
    }

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(temporary_path, Ymlr.document!({@header, document}, sort_maps: true)) do
      File.rename(temporary_path, path)
    end
  end

  @doc "Returns the path of the file holding a collection."
  @spec file_path(Path.t(), Snapshot.collection()) :: Path.t()
  def file_path(directory, collection), do: Path.join(directory, "#{collection}.yaml")

  defp encode_records(records) do
    Map.new(records, fn record ->
      attributes =
        record
        |> Codec.encode()
        |> Map.delete(@identifier_key)

      {record.id, attributes}
    end)
  end

  defp load_collection(directory, collection) do
    path = file_path(directory, collection)
    file_name = Path.basename(path)

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         [] <- DuplicateKeys.find(content, Atom.to_string(collection)),
         {:ok, document} <- parse(content) do
      decode_document(document, file_name, collection)
    else
      false -> {:ok, []}
      {:error, reason} -> {:error, ["#{file_name}: #{format_reason(reason)}"]}
      duplicates -> {:error, Enum.map(duplicates, &"#{file_name}: duplicate id #{&1}")}
    end
  end

  defp parse(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, document} -> {:ok, document}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp decode_document(%{"version" => @format_version} = document, file_name, collection) do
    case Map.get(document, Atom.to_string(collection)) do
      nil -> {:ok, []}
      entries when is_map(entries) -> decode_records(entries, file_name, collection)
      _other -> {:error, ["#{file_name}: expected `#{collection}` to map identifiers to entries"]}
    end
  end

  defp decode_document(document, file_name, _collection) when is_map(document),
    do: {:error, ["#{file_name}: expected `version: #{@format_version}`"]}

  defp decode_document(_document, file_name, _collection),
    do: {:error, ["#{file_name}: expected a mapping at the top level"]}

  defp decode_records(entries, file_name, collection) do
    results =
      entries
      |> Enum.sort_by(fn {id, _attributes} -> to_string(id) end)
      |> Enum.map(fn {id, attributes} ->
        decode_record(to_string(id), attributes, file_name, collection)
      end)

    case Enum.split_with(results, &match?({:ok, _record}, &1)) do
      {successes, []} -> {:ok, Enum.map(successes, fn {:ok, record} -> record end)}
      {_successes, failures} -> {:error, Enum.map(failures, fn {:error, message} -> message end)}
    end
  end

  defp decode_record(id, attributes, file_name, collection)
       when is_map(attributes) or is_nil(attributes) do
    attributes = Map.put(attributes || %{}, @identifier_key, id)

    case Codec.decode(collection, attributes) do
      {:ok, record} -> {:ok, record}
      {:error, changeset} -> {:error, "#{file_name} (#{id}): #{describe_errors(changeset)}"}
    end
  end

  defp decode_record(id, _attributes, file_name, _collection),
    do: {:error, "#{file_name} (#{id}): expected a mapping"}

  defp describe_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, options} ->
      Regex.replace(~r"%{(\w+)}", message, fn _match, key ->
        options
        |> Keyword.get(String.to_existing_atom(key), key)
        |> to_string()
      end)
    end)
    |> inspect()
  end
end
