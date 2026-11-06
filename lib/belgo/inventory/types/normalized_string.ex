defmodule Belgo.Inventory.Types.NormalizedString do
  @moduledoc """
  Builds an Ecto type storing a string normalised by the using module's `normalize/1`.

  Invalid input fails casting, which surfaces as a regular changeset error.
  """

  @doc "Normalises a raw string, returning `:error` when it is invalid."
  @callback normalize(String.t()) :: {:ok, String.t()} | :error

  defmacro __using__(_options) do
    quote do
      use Ecto.Type

      @behaviour Belgo.Inventory.Types.NormalizedString

      @impl Ecto.Type
      def type, do: :string

      @impl Ecto.Type
      def cast(value) when is_binary(value), do: normalize(value)
      def cast(_value), do: :error

      @impl Ecto.Type
      def load(value), do: {:ok, value}

      @impl Ecto.Type
      def dump(value), do: {:ok, value}
    end
  end
end
