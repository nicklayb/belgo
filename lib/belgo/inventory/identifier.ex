defmodule Belgo.Inventory.Identifier do
  @moduledoc """
  Slug identifiers used as primary keys and as references between records.

  Identifiers are what the YAML files reference, so they must be stable and readable.
  """

  import Ecto.Changeset

  @format ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @invalid_characters ~r/[^a-z0-9]+/
  @apostrophes ~r/['’]/u

  @doc "Turns any name into a slug (`Apple TV Salon` becomes `apple-tv-salon`)."
  @spec slugify(String.t()) :: String.t()
  def slugify(name) do
    name
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(@apostrophes, "")
    |> String.replace(@invalid_characters, "-")
    |> String.trim("-")
  end

  @doc "Fills `:id` from the slug of `source_field` when no identifier was given."
  @spec put_default(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def put_default(changeset, source_field) do
    case {get_field(changeset, :id), get_field(changeset, source_field)} do
      {nil, source} when is_binary(source) -> put_change(changeset, :id, slugify(source))
      _ -> changeset
    end
  end

  @doc "Validates that a field contains a well formed identifier."
  @spec validate(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate(changeset, field) do
    validate_format(changeset, field, @format,
      message: "must only contain lowercase letters, digits and dashes"
    )
  end
end
