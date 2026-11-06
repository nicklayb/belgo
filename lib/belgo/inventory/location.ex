defmodule Belgo.Inventory.Location do
  @moduledoc """
  A physical place where devices live. Locations nest through `parent_id`
  (house, floor, room, rack...).

  `home_assistant_id` links the location to a Home Assistant floor (`floor/<floor_id>`)
  or area (`area/<area_id>`), so renames there show up as divergences.
  """

  use Belgo, :schema

  alias Belgo.Inventory.Identifier

  @kinds ~w(site building floor room rack other)a
  @fields ~w(id name kind parent_id notes home_assistant_id)a
  @home_assistant_id_format ~r/\A(floor|area)\/[^\s\/]+\z/
  @required ~w(id name kind)a

  embedded_schema do
    field(:name, :string)
    field(:kind, Ecto.Enum, values: @kinds, default: :room)
    field(:parent_id, :string)
    field(:notes, :string)
    field(:home_assistant_id, :string)
  end

  @doc "Lists the available location kinds."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "Builds a changeset validating the location on its own."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(location, params) do
    location
    |> cast(params, @fields)
    |> Identifier.put_default(:name)
    |> validate_required(@required)
    |> Identifier.validate(:id)
    |> Identifier.validate(:parent_id)
    |> validate_not_own_parent()
    |> validate_format(:home_assistant_id, @home_assistant_id_format,
      message: "must look like floor/<floor_id> or area/<area_id>"
    )
  end

  defp validate_not_own_parent(changeset) do
    if get_field(changeset, :parent_id) != nil and
         get_field(changeset, :parent_id) == get_field(changeset, :id) do
      add_error(changeset, :parent_id, "cannot be the location itself")
    else
      changeset
    end
  end
end
