defmodule Belgo.Inventory.Codec do
  @moduledoc """
  Converts records to and from the plain maps written in the data files.

  Encoding omits empty values (`nil`, `[]`, `false`, `""`) to keep files short and
  readable. Decoding runs the record changeset so files get the same validation as forms.
  """

  alias Belgo.Inventory.Snapshot

  @omitted_values [nil, [], false, ""]

  @doc "Encodes a record (or embedded record) to a map with string keys."
  @spec encode(struct()) :: %{String.t() => any()}
  def encode(%schema{} = record) do
    :fields
    |> schema.__schema__()
    |> Enum.map(fn field -> {Atom.to_string(field), encode_value(Map.fetch!(record, field))} end)
    |> Enum.reject(fn {_field, value} -> value in @omitted_values end)
    |> Map.new()
  end

  @doc "Decodes a map read from a file into a record of the collection."
  @spec decode(Snapshot.collection(), map()) ::
          {:ok, Snapshot.entity()} | {:error, Ecto.Changeset.t()}
  def decode(collection, attributes) when is_map(attributes) do
    schema = Snapshot.schema(collection)

    schema
    |> struct()
    |> schema.changeset(attributes)
    |> Ecto.Changeset.apply_action(:load)
  end

  defp encode_value(value) when is_struct(value), do: encode(value)
  defp encode_value(values) when is_list(values), do: Enum.map(values, &encode_value/1)
  defp encode_value(value) when is_boolean(value) or is_nil(value), do: value
  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(value), do: value
end
