defmodule Belgo.Inventory.ListParams do
  @moduledoc """
  Normalises list params so forms can submit comma separated strings: values are
  trimmed, blanks and duplicates removed.
  """

  @doc "Normalises the given string keys of a params map."
  @spec normalize(map(), [String.t()]) :: map()
  def normalize(params, fields) do
    Enum.reduce(fields, params, fn field, accumulator ->
      case Map.fetch(accumulator, field) do
        {:ok, value} -> Map.put(accumulator, field, split(value))
        :error -> accumulator
      end
    end)
  end

  defp split(value) when is_binary(value), do: split(String.split(value, ","))

  defp split(values) when is_list(values) do
    values
    |> Enum.map(&String.trim(to_string(&1)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp split(value), do: value
end
