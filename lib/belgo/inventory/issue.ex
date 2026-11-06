defmodule Belgo.Inventory.Issue do
  @moduledoc "An inconsistency found in the inventory, attached to one record."

  alias Belgo.Inventory.Snapshot

  @enforce_keys [:severity, :collection, :id, :field, :message]
  defstruct [:severity, :collection, :id, :field, :message]

  @type severity :: :error | :warning
  @type t :: %__MODULE__{
          severity: severity(),
          collection: Snapshot.collection(),
          id: String.t(),
          field: atom(),
          message: String.t()
        }

  @doc "Builds a blocking issue."
  @spec error(Snapshot.collection(), String.t(), atom(), String.t()) :: t()
  def error(collection, id, field, message), do: build(:error, collection, id, field, message)

  @doc "Builds a non blocking issue."
  @spec warning(Snapshot.collection(), String.t(), atom(), String.t()) :: t()
  def warning(collection, id, field, message),
    do: build(:warning, collection, id, field, message)

  defp build(severity, collection, id, field, message) do
    %__MODULE__{
      severity: severity,
      collection: collection,
      id: id,
      field: field,
      message: message
    }
  end
end
