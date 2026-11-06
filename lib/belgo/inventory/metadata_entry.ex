defmodule Belgo.Inventory.MetadataEntry do
  @moduledoc """
  A free metadata field of a device (`Brand: Apple`, `Serial number: …`). Devices
  only carry the entries that were added: there are no empty fields.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{label: String.t(), value: String.t()}

  @suggested_labels [
    "Brand",
    "Model",
    "Serial number",
    "Operating system",
    "Firmware",
    "Purchase date",
    "Warranty until",
    "Owner",
    "Asset tag"
  ]
  @maximum_label_length 64

  @primary_key false
  embedded_schema do
    field(:label, :string)
    field(:value, :string)
  end

  @doc "Labels proposed when adding an entry; any other label is allowed."
  @spec suggested_labels() :: [String.t()]
  def suggested_labels, do: @suggested_labels

  @doc "Builds a changeset; both the label and the value are required."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, params) do
    entry
    |> cast(params, [:label, :value])
    |> update_change(:label, &String.trim/1)
    |> update_change(:value, &String.trim/1)
    |> validate_required([:label, :value])
    |> validate_length(:label, max: @maximum_label_length)
  end
end
