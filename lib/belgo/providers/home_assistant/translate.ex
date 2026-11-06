defmodule Belgo.Providers.HomeAssistant.Translate do
  @moduledoc """
  Turns Home Assistant registry entries into location observations. Pure functions.

  Floors (`floor_id`, `name`, `level`) and areas (`area_id`, `name`, `floor_id`) are
  referenced as `floor/<floor_id>` and `area/<area_id>`, the format of
  `Location.home_assistant_id`.
  """

  alias Belgo.Discovery.Observation

  @provider :home_assistant

  @doc "Builds the reference of a floor."
  @spec floor_reference(String.t()) :: String.t()
  def floor_reference(floor_id), do: "floor/#{floor_id}"

  @doc "Builds the reference of an area."
  @spec area_reference(String.t()) :: String.t()
  def area_reference(area_id), do: "area/#{area_id}"

  @doc "Translates floor registry entries."
  @spec floors([map()]) :: [Observation.t()]
  def floors(entries) do
    for %{"floor_id" => floor_id, "name" => name} = entry <- entries,
        present?(floor_id) and present?(name) do
      %Observation{
        provider: @provider,
        source: :home_assistant_floor,
        kind: :location,
        reference: floor_reference(floor_id),
        name: String.trim(name),
        level: level(entry["level"])
      }
    end
  end

  @doc "Translates area registry entries."
  @spec areas([map()]) :: [Observation.t()]
  def areas(entries) do
    for %{"area_id" => area_id, "name" => name} = entry <- entries,
        present?(area_id) and present?(name) do
      %Observation{
        provider: @provider,
        source: :home_assistant_area,
        kind: :location,
        reference: area_reference(area_id),
        name: String.trim(name),
        parent_reference: if(present?(entry["floor_id"]), do: floor_reference(entry["floor_id"]))
      }
    end
  end

  defp level(level) when is_integer(level), do: level
  defp level(_level), do: nil

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
