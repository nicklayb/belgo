defmodule Belgo.Fixtures.HomeAssistantClient do
  @moduledoc """
  Home Assistant of 742 Evergreen Terrace: a ground floor (Kitchen, Living Room) and
  a basement floor (Basement, Moe's Corner), plus a Tree House area without floor.
  The `broken.example` instance refuses the token.
  """

  @behaviour Belgo.Providers.HomeAssistant.Client

  @impl Belgo.Providers.HomeAssistant.Client
  def registries(%{url: "https://broken.example"}),
    do: {:error, {:auth_invalid, "Invalid access token or password"}}

  def registries(_config) do
    {:ok,
     %{
       floors: [
         %{"floor_id" => "ground_floor", "name" => "Ground Floor", "level" => 0},
         %{"floor_id" => "basement", "name" => "Basement Floor", "level" => -1}
       ],
       areas: [
         %{"area_id" => "kitchen", "name" => "Kitchen", "floor_id" => "ground_floor"},
         %{"area_id" => "living_room", "name" => "Living Room", "floor_id" => "ground_floor"},
         %{"area_id" => "basement", "name" => "Basement", "floor_id" => "basement"},
         %{"area_id" => "moes_corner", "name" => "Moe's Corner", "floor_id" => "basement"},
         %{"area_id" => "tree_house", "name" => "Tree House", "floor_id" => nil}
       ]
     }}
  end
end
