defmodule Belgo do
  @moduledoc """
  Shared `use` macros for Belgo modules, and the application version.

      use Belgo, :schema
  """

  @doc "Application version, from the generated `.app` (filled by `mix.exs` from `VERSION`)."
  @spec version() :: String.t()
  def version do
    :belgo
    |> Application.spec(:vsn)
    |> to_string()
  end

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
