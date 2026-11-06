defmodule Belgo.Inventory.MetadataLabels do
  @moduledoc """
  Index of the metadata labels: those already used by devices, then the suggested
  ones. Labels are compared case insensitively; the spelling used by the most devices
  wins (`brand` typed for a new entry is saved as the existing `Brand`). The form
  offers them through a `<datalist>`, which browsers filter case insensitively.

  Values are indexed the same way, per label, so typing `App` for `Brand` proposes
  `Apple` when a device already has it. Pure.
  """

  alias Belgo.Inventory.MetadataEntry
  alias Belgo.Inventory.Snapshot

  @doc "Lists the labels, most used first, then the suggested labels nobody uses yet."
  @spec list(Snapshot.t()) :: [String.t()]
  def list(%Snapshot{} = snapshot) do
    used = used_labels(snapshot.devices)
    used_keys = MapSet.new(used, &key/1)

    used ++ Enum.reject(MetadataEntry.suggested_labels(), &MapSet.member?(used_keys, key(&1)))
  end

  @doc """
  Lists the values used for each label (indexed spelling), most used first, values
  compared case insensitively.
  """
  @spec values(Snapshot.t()) :: %{String.t() => [String.t()]}
  def values(%Snapshot{} = snapshot) do
    snapshot.devices
    |> Enum.flat_map(& &1.metadata)
    |> Enum.group_by(&key(&1.label), & &1)
    |> Map.new(fn {_key, entries} ->
      {most_used(Enum.map(entries, & &1.label)), by_usage(Enum.map(entries, & &1.value))}
    end)
  end

  @doc "Lists every value used by any label, most used first."
  @spec all_values(%{String.t() => [String.t()]}) :: [String.t()]
  def all_values(values_by_label) do
    values_by_label
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq_by(&key/1)
    |> Enum.sort_by(&key/1)
  end

  @doc "Returns the values used for a label (case insensitive), `nil` for an unknown label."
  @spec values_for(%{String.t() => [String.t()]}, String.t() | nil) :: [String.t()] | nil
  def values_for(values_by_label, label) do
    Enum.find_value(values_by_label, fn {indexed, values} ->
      if key(indexed) == key(label) and key(label) != "", do: values
    end)
  end

  @doc "Returns the indexed spelling of a label, or the label itself when it is new."
  @spec canonical(String.t(), [String.t()]) :: String.t()
  def canonical(label, labels) when is_binary(label),
    do: Enum.find(labels, label, &(key(&1) == key(label)))

  defp by_usage(values) do
    values
    |> Enum.group_by(&key/1)
    |> Enum.map(fn {_key, spellings} -> {most_used(spellings), length(spellings)} end)
    |> Enum.sort_by(fn {value, count} -> {-count, key(value)} end)
    |> Enum.map(fn {value, _count} -> value end)
  end

  defp used_labels(devices) do
    devices
    |> Enum.flat_map(fn device -> Enum.map(device.metadata, & &1.label) end)
    |> Enum.group_by(&key/1)
    |> Enum.map(fn {_key, spellings} -> {most_used(spellings), length(spellings)} end)
    |> Enum.sort_by(fn {label, count} -> {-count, key(label)} end)
    |> Enum.map(fn {label, _count} -> label end)
  end

  defp most_used(spellings) do
    spellings
    |> Enum.frequencies()
    |> Enum.min_by(fn {spelling, count} -> {-count, spelling} end)
    |> elem(0)
  end

  defp key(label) when is_binary(label),
    do:
      label
      |> String.trim()
      |> String.downcase()

  defp key(_label), do: ""
end
