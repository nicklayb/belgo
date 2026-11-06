defmodule Belgo.Inventory.SortParams do
  @moduledoc """
  Fixes the `*_sort` params of embedded lists in forms. An "Add" button sends its
  value (`"new"`) where it sits in the DOM: placed above the entries, the new entry
  would come first and shift the others while the user types. New entries always go
  last.
  """

  @new_entry "new"

  @doc "Moves the new entries of the given sort params to the end."
  @spec new_last(map(), [String.t()]) :: map()
  def new_last(params, sort_keys) do
    Enum.reduce(sort_keys, params, fn key, accumulator ->
      case Map.fetch(accumulator, key) do
        {:ok, positions} when is_list(positions) ->
          {new_entries, existing} = Enum.split_with(positions, &(&1 == @new_entry))
          Map.put(accumulator, key, existing ++ new_entries)

        _missing_or_other ->
          accumulator
      end
    end)
  end
end
