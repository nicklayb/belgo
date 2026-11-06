defmodule Belgo.Inventory.Storage.DuplicateKeys do
  @moduledoc """
  Finds identifiers written twice under a collection of a YAML file.

  YAML parsers silently keep only one of duplicated keys, which would hide a record
  edited by hand. This scans the block style lines (the style Belgo writes) directly
  under the collection key; flow style mappings are not inspected.
  """

  @key_line ~r/\A(?<indentation>\s+)(?<quote>["']?)(?<key>[^\s#"']+?)\k<quote>:(\s|\z)/

  @doc "Lists the identifiers appearing more than once under `collection`."
  @spec find(String.t(), String.t()) :: [String.t()]
  def find(content, collection) do
    content
    |> String.split(["\r\n", "\n"])
    |> collection_lines(collection)
    |> child_keys()
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(fn {key, _count} -> key end)
    |> Enum.sort()
  end

  defp collection_lines(lines, collection) do
    lines
    |> Enum.drop_while(&(not String.match?(&1, ~r/\A#{Regex.escape(collection)}:\s*(#.*)?\z/)))
    |> Enum.drop(1)
    |> Enum.reject(&blank_or_comment?/1)
    |> Enum.take_while(&String.starts_with?(&1, [" ", "\t"]))
  end

  defp child_keys([]), do: []

  defp child_keys([first_line | _rest] = lines) do
    child_indentation = indentation(first_line)

    lines
    |> Enum.filter(&(indentation(&1) == child_indentation))
    |> Enum.flat_map(fn line ->
      case Regex.named_captures(@key_line, line) do
        %{"key" => key} -> [key]
        nil -> []
      end
    end)
  end

  defp indentation(line), do: byte_size(line) - byte_size(String.trim_leading(line))

  defp blank_or_comment?(line) do
    trimmed = String.trim(line)
    trimmed == "" or String.starts_with?(trimmed, "#")
  end
end
