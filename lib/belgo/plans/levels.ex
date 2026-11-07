defmodule Belgo.Plans.Levels do
  @moduledoc """
  Heights of the levels of a plan, from their relative definitions: a level stands
  `offset` times its base level's height above that base (a reference level, without
  base, `offset` times its own height above 0). A level without its own `height` /
  `wall_height` uses the home's. Pure functions.
  """

  alias Belgo.Plans.Level
  alias Belgo.Plans.Plan

  @doc "Floor to floor height of a level (its own, else the home's default)."
  @spec height(Level.t(), Plan.t()) :: pos_integer()
  def height(%Level{height: nil}, %Plan{level_height: level_height}), do: level_height
  def height(%Level{height: height}, _plan), do: height

  @doc "Wall height of a level (its own, else the home's default)."
  @spec wall_height(Level.t(), Plan.t()) :: pos_integer()
  def wall_height(%Level{wall_height: nil}, %Plan{wall_height: wall_height}), do: wall_height
  def wall_height(%Level{wall_height: wall_height}, _plan), do: wall_height

  @doc "Floor to floor height of each level of the plan, by level id."
  @spec heights(Plan.t()) :: %{String.t() => pos_integer()}
  def heights(%Plan{} = plan), do: Map.new(plan.levels, &{&1.id, height(&1, plan)})

  @doc "Wall height of each level of the plan, by level id."
  @spec wall_heights(Plan.t()) :: %{String.t() => pos_integer()}
  def wall_heights(%Plan{} = plan), do: Map.new(plan.levels, &{&1.id, wall_height(&1, plan)})

  @doc """
  Elevation of each level in centimetres, the reference levels (without base) at 0
  plus their offset. `default_height` is the home's level height. An error names the
  levels whose base is unknown or part of a cycle.
  """
  @spec elevations([Level.t()], pos_integer()) ::
          {:ok, %{String.t() => float()}} | {:error, [String.t()]}
  def elevations(levels, default_height) do
    level_by_id = Map.new(levels, &{&1.id, &1})

    results =
      Map.new(levels, fn level ->
        {level.id, resolve(level, level_by_id, default_height, [])}
      end)

    case for({id, :error} <- results, do: id) do
      [] -> {:ok, Map.new(results, fn {id, {:ok, elevation}} -> {id, elevation} end)}
      invalid -> {:error, Enum.sort(invalid)}
    end
  end

  defp resolve(%Level{base_id: nil} = level, _level_by_id, default_height, _visited),
    do: {:ok, level.offset * (level.height || default_height)}

  defp resolve(%Level{} = level, level_by_id, default_height, visited) do
    with false <- level.id in visited,
         {:ok, base} <- Map.fetch(level_by_id, level.base_id),
         {:ok, base_elevation} <-
           resolve(base, level_by_id, default_height, [level.id | visited]) do
      {:ok, base_elevation + level.offset * (base.height || default_height)}
    else
      _unknown_or_cycle -> :error
    end
  end
end
