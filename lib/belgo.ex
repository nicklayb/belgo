defmodule Belgo do
  @moduledoc """
  Shared `use` macros for Belgo modules.

      use Belgo, :schema
  """

  @doc "Embedded schema whose primary key is a human readable slug."
  def schema do
    quote do
      use Ecto.Schema

      import Ecto.Changeset

      @type t :: %__MODULE__{}

      @primary_key {:id, :string, autogenerate: false}
    end
  end

  defmacro __using__(type) when is_atom(type) do
    apply(__MODULE__, type, [])
  end
end
