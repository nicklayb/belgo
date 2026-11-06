defmodule Belgo.Plans.Levels do
  @moduledoc """
  Absolute heights of the levels of a plan, from their relative definitions (`base_id`
  and `offset` in levels of `level_height` centimetres). Pure functions.
  """

  alias Belgo.Plans.Level

  @doc """
  Elevation of each level in centimetres, the reference levels (without base) at 0.
  An error names the levels whose base is unknown or part of a cycle.
  """
  @spec elevations([Level.t()], pos_integer()) ::
          {:ok, %{String.t() => float()}} | {:error, [String.t()]}
  def elevations(levels, level_height) do
    level_by_id = Map.new(levels, &{&1.id, &1})

    results =
      Map.new(levels, fn level -> {level.id, resolve(level, level_by_id, level_height, [])} end)

    case for({id, :error} <- results, do: id) do
      [] -> {:ok, Map.new(results, fn {id, {:ok, elevation}} -> {id, elevation} end)}
      invalid -> {:error, Enum.sort(invalid)}
    end
  end

  defp resolve(%Level{base_id: nil} = level, _level_by_id, level_height, _visited),
    do: {:ok, level.offset * level_height}

  defp resolve(%Level{} = level, level_by_id, level_height, visited) do
    with false <- level.id in visited,
         {:ok, base} <- Map.fetch(level_by_id, level.base_id),
         {:ok, base_elevation} <- resolve(base, level_by_id, level_height, [level.id | visited]) do
      {:ok, base_elevation + level.offset * level_height}
    else
      _unknown_or_cycle -> :error
    end
  end
end
