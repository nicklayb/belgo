defmodule Belgo.Inventory.BulkEdit do
  @moduledoc """
  Changes applied to several devices at once: the kind, the placement (a location,
  portable or unplaced) and metadata entries. Fields left empty keep each device's
  current value.

  Conflicts are overwritten: a metadata entry replaces the value of the entry with the
  same label (case insensitive) on each device, other entries are kept; a placement
  replaces the current one (a hosted guest moved to a location is no longer hosted);
  a kind other than `network` drops the network role, which would force it back.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Belgo.Inventory.Codec
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.MetadataEntry
  alias Belgo.Inventory.SortParams

  @placements ~w(keep location portable unplaced)a

  @primary_key false
  embedded_schema do
    field(:kind, Ecto.Enum, values: Device.kinds())
    field(:placement, Ecto.Enum, values: @placements, default: :keep)
    field(:location_id, :string)
    embeds_many(:metadata, MetadataEntry, on_replace: :delete)
  end

  @type t :: %__MODULE__{
          kind: atom() | nil,
          placement: :keep | :location | :portable | :unplaced,
          location_id: String.t() | nil,
          metadata: [MetadataEntry.t()]
        }

  @doc "Lists the placement choices, `:keep` leaving each device where it is."
  @spec placements() :: [atom()]
  def placements, do: @placements

  @doc "Builds a changeset; at least one change is required."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(bulk_edit \\ %__MODULE__{}, params) do
    params = SortParams.new_last(params, ["metadata_sort"])

    bulk_edit
    |> cast(params, [:kind, :placement, :location_id])
    |> cast_embed(:metadata,
      with: &MetadataEntry.changeset/2,
      sort_param: :metadata_sort,
      drop_param: :metadata_drop
    )
    |> validate_location()
    |> validate_unique_labels()
    |> validate_has_change()
  end

  @doc "Returns `true` when the edit changes nothing."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{kind: nil, placement: :keep, metadata: []}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc "Computes the attributes of a device once the edit is applied."
  @spec device_params(t(), Device.t()) :: map()
  def device_params(%__MODULE__{} = bulk_edit, %Device{} = device) do
    device
    |> Codec.encode()
    |> put_kind(bulk_edit.kind)
    |> put_placement(bulk_edit)
    |> put_metadata(bulk_edit.metadata)
  end

  defp put_kind(attributes, nil), do: attributes
  defp put_kind(attributes, :network), do: Map.put(attributes, "kind", "network")

  defp put_kind(attributes, kind) do
    attributes
    |> Map.put("kind", Atom.to_string(kind))
    |> Map.delete("network_role")
  end

  defp put_placement(attributes, %__MODULE__{placement: :keep}), do: attributes

  defp put_placement(attributes, %__MODULE__{placement: :location, location_id: location_id}) do
    Map.merge(attributes, %{"placement" => "location", "location_id" => location_id})
  end

  defp put_placement(attributes, %__MODULE__{placement: placement}),
    do: Map.put(attributes, "placement", Atom.to_string(placement))

  defp put_metadata(attributes, []), do: attributes

  defp put_metadata(attributes, entries) do
    current = Map.get(attributes, "metadata", [])

    updated =
      Enum.reduce(entries, current, fn entry, accumulator ->
        replace_or_append(accumulator, %{"label" => entry.label, "value" => entry.value})
      end)

    Map.put(attributes, "metadata", updated)
  end

  defp replace_or_append(entries, new_entry) do
    key = label_key(new_entry["label"])

    if Enum.any?(entries, &(label_key(&1["label"]) == key)),
      do: Enum.map(entries, &replace_entry(&1, key, new_entry)),
      else: entries ++ [new_entry]
  end

  defp replace_entry(entry, key, new_entry) do
    if label_key(entry["label"]) == key, do: new_entry, else: entry
  end

  defp label_key(label),
    do:
      label
      |> String.trim()
      |> String.downcase()

  defp validate_location(changeset) do
    if get_field(changeset, :placement) == :location,
      do: validate_required(changeset, [:location_id], message: "choose a location"),
      else: changeset
  end

  defp validate_unique_labels(changeset) do
    labels =
      changeset
      |> get_field(:metadata)
      |> Enum.map(&(&1.label && label_key(&1.label)))
      |> Enum.reject(&(&1 in [nil, ""]))

    if labels == Enum.uniq(labels),
      do: changeset,
      else: add_error(changeset, :metadata, "each label can only be used once")
  end

  defp validate_has_change(changeset) do
    if changeset.valid? and empty?(apply_changes(changeset)),
      do: add_error(changeset, :kind, "choose at least one change"),
      else: changeset
  end
end
