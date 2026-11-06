defmodule Belgo.Inventory.DeniedDevice do
  @moduledoc """
  A MAC address whose discovered device must never be suggested (guest phones,
  randomised addresses...). Its identifier is the normalised MAC address.
  """

  use Belgo, :schema

  alias Belgo.Network.MacAddress

  embedded_schema do
    field(:name, :string)
    field(:note, :string)
  end

  @doc "Builds a changeset validating the entry on its own."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(denied_device, params) do
    denied_device
    |> cast(params, [:id, :name, :note])
    |> validate_required([:id])
    |> normalize_mac()
  end

  defp normalize_mac(changeset) do
    case changeset
         |> get_field(:id)
         |> MacAddress.normalize() do
      {:ok, mac} -> put_change(changeset, :id, mac)
      :error -> add_error(changeset, :id, "must be a MAC address")
    end
  end
end
