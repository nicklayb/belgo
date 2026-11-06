defmodule Belgo.Inventory.Changes do
  @moduledoc """
  Builds changesets validated both on their own and against the rest of the inventory.
  """

  import Ecto.Changeset

  alias Belgo.Inventory.Audit
  alias Belgo.Inventory.MetadataLabels
  alias Belgo.Inventory.Snapshot

  @doc """
  Builds a changeset for a new record (`nil`) or an existing one. Blocking
  `Belgo.Inventory.Audit` issues of the resulting record become changeset errors.
  Device metadata labels take the spelling already used by other devices.
  """
  @spec build(Snapshot.t(), Snapshot.collection(), Snapshot.entity() | nil, map()) ::
          Ecto.Changeset.t()
  def build(%Snapshot{} = snapshot, collection, record, params) do
    schema = Snapshot.schema(collection)
    changeset = schema.changeset(record || struct(schema), params)

    changeset
    |> keep_identifier(record)
    |> validate_unique_identifier(snapshot, collection, record)
    |> canonicalize_metadata_labels(snapshot, collection)
    |> validate_against(snapshot, collection)
  end

  # Rewrites labels inside the entry changesets: rebuilding the entries would lose
  # their form identity (`_persistent_id`) and mix up fields being typed in.
  defp canonicalize_metadata_labels(%Ecto.Changeset{valid?: true} = changeset, snapshot, :devices) do
    labels =
      snapshot
      |> Snapshot.delete(:devices, get_field(changeset, :id))
      |> MetadataLabels.list()

    update_change(changeset, :metadata, fn entries ->
      Enum.map(entries, &canonicalize_entry(&1, labels))
    end)
  end

  defp canonicalize_metadata_labels(changeset, _snapshot, _collection), do: changeset

  defp canonicalize_entry(%Ecto.Changeset{} = entry, labels) do
    case get_field(entry, :label) do
      label when is_binary(label) ->
        put_change(entry, :label, MetadataLabels.canonical(label, labels))

      _missing ->
        entry
    end
  end

  defp keep_identifier(changeset, nil), do: changeset
  defp keep_identifier(changeset, %{id: id}), do: put_change(changeset, :id, id)

  defp validate_unique_identifier(changeset, snapshot, collection, nil) do
    case Snapshot.fetch(snapshot, collection, get_field(changeset, :id)) do
      {:ok, _existing} -> add_error(changeset, :id, "is already taken")
      {:error, :not_found} -> changeset
    end
  end

  defp validate_unique_identifier(changeset, _snapshot, _collection, _record), do: changeset

  defp validate_against(%Ecto.Changeset{valid?: false} = changeset, _snapshot, _collection),
    do: changeset

  defp validate_against(changeset, snapshot, collection) do
    record = apply_changes(changeset)

    snapshot
    |> Snapshot.put(collection, record)
    |> Audit.issues()
    |> Audit.issues_for(collection, record.id)
    |> Enum.filter(&(&1.severity == :error))
    |> Enum.reduce(changeset, fn issue, accumulator ->
      add_error(accumulator, issue.field, issue.message)
    end)
  end
end
