defmodule Belgo.Providers.HomeAssistantTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.Correlation.Divergence
  alias Belgo.Discovery.Locations.DiscoveredLocation
  alias Belgo.Discovery.Observation
  alias Belgo.Discovery.Suggestion
  alias Belgo.Fixtures
  alias Belgo.Fixtures.HomeAssistantClient
  alias Belgo.Inventory.Audit
  alias Belgo.Inventory.Location
  alias Belgo.Inventory.Snapshot
  alias Belgo.Providers.HomeAssistant
  alias Belgo.Providers.HomeAssistant.Translate

  defp config(url \\ "https://homeassistant.springfield.lan") do
    %HomeAssistant.Config{url: url, token: "mmm-donuts", client: HomeAssistantClient}
  end

  defp observations do
    {:ok, report} = HomeAssistant.discover(config())
    report.observations
  end

  defp new_locations(snapshot) do
    Correlation.build(snapshot, observations()).new_locations
  end

  test "parses its configuration, the token being a secret" do
    environment = %{"BELGO_HOME_ASSISTANT_TOKEN" => "mmm-donuts"}

    assert {:ok,
            %HomeAssistant.Config{url: "https://ha:8123", token: "mmm-donuts", verify_tls: true}} =
             HomeAssistant.parse_config(%{"url" => "https://ha:8123/"}, environment)

    assert {:error, messages} =
             HomeAssistant.parse_config(%{"url" => "https://ha", "token" => "x"}, %{})

    assert Enum.any?(messages, &(&1 =~ "unknown options: token"))
    assert Enum.any?(messages, &(&1 =~ "BELGO_HOME_ASSISTANT_TOKEN"))
  end

  test "floors and areas become location observations referenced by their id" do
    assert [
             %Observation{
               kind: :location,
               source: :home_assistant_floor,
               reference: "floor/ground_floor",
               name: "Ground Floor",
               level: 0
             },
             %Observation{reference: "floor/basement", level: -1},
             %Observation{
               source: :home_assistant_area,
               reference: "area/kitchen",
               parent_reference: "floor/ground_floor"
             },
             _living_room,
             _basement,
             _moes_corner,
             %Observation{reference: "area/tree_house", parent_reference: nil}
           ] = observations()
  end

  test "entries without id or name are skipped" do
    assert [] == Translate.floors([%{"floor_id" => "attic", "name" => " "}])
    assert [] == Translate.areas([%{"name" => "Attic"}])
  end

  test "a refused token fails the discovery" do
    assert {:error, {:auth_invalid, _message}} =
             HomeAssistant.discover(config("https://broken.example"))
  end

  test "unknown floors and areas are new locations, grouped by floor from the lowest level" do
    assert [
             "Basement Floor",
             "Moe's Corner",
             "Ground Floor",
             "Kitchen",
             "Tree House"
           ] == Enum.map(new_locations(Fixtures.snapshot()), & &1.name)
  end

  test "locations of the same name are matched without link" do
    names = Enum.map(new_locations(Fixtures.snapshot()), & &1.name)

    refute "Living Room" in names
    refute "Basement" in names
  end

  test "an area knows the inventory location of its floor" do
    snapshot =
      Snapshot.put(
        Fixtures.snapshot(),
        :locations,
        Fixtures.location(
          id: "ground",
          name: "Rez-de-chaussée",
          kind: :floor,
          parent_id: "evergreen-terrace",
          home_assistant_id: "floor/ground_floor"
        )
      )

    assert %DiscoveredLocation{kind: :room, parent_id: "ground", parent_name: "Ground Floor"} =
             Enum.find(new_locations(snapshot), &(&1.name == "Kitchen"))
  end

  test "a linked location reports renames and a floor that is not its ancestor" do
    snapshot =
      Fixtures.snapshot()
      |> Snapshot.put(
        :locations,
        Fixtures.location(
          id: "ground",
          name: "Ground Floor",
          kind: :floor,
          parent_id: "evergreen-terrace",
          home_assistant_id: "floor/ground_floor"
        )
      )
      |> Snapshot.put(
        :locations,
        Fixtures.location(
          id: "kitchen",
          name: "Cuisine",
          kind: :room,
          parent_id: "evergreen-terrace",
          home_assistant_id: "area/kitchen"
        )
      )

    correlation = Correlation.build(snapshot, observations())

    assert [
             %Divergence{
               provider: :home_assistant,
               message: "is on Ground Floor, Belgo has it inside 742 Evergreen Terrace"
             },
             %Divergence{message: "name is Kitchen, Belgo has Cuisine"}
           ] = Correlation.divergences_for(correlation, :locations, "kitchen")

    refute Enum.any?(correlation.new_locations, &(&1.reference == "area/kitchen"))

    assert [] == Correlation.divergences_for(correlation, :locations, "ground")

    assert [%Divergence{message: "is on Ground Floor, Belgo has it inside 742 Evergreen Terrace"}] =
             Correlation.divergences_for(correlation, :locations, "living-room")
  end

  test "claiming suggests the floor, else the only site, and links the location" do
    snapshot = Fixtures.snapshot()
    ground_floor = Enum.find(new_locations(snapshot), &(&1.name == "Ground Floor"))

    assert %{
             "name" => "Ground Floor",
             "kind" => "floor",
             "parent_id" => "evergreen-terrace",
             "home_assistant_id" => "floor/ground_floor"
           } == Suggestion.location_params(ground_floor, snapshot)
  end

  test "home_assistant_id must reference a floor or an area, once" do
    refute Location.changeset(%Location{}, %{"name" => "Attic", "home_assistant_id" => "attic"}).valid?

    assert Location.changeset(%Location{}, %{
             "name" => "Attic",
             "home_assistant_id" => "area/attic"
           }).valid?

    snapshot =
      Enum.reduce(["attic", "loft"], Fixtures.snapshot(), fn id, snapshot ->
        Snapshot.put(
          snapshot,
          :locations,
          Fixtures.location(id: id, name: id, home_assistant_id: "area/attic")
        )
      end)

    assert [
             %{
               field: :home_assistant_id,
               message: "Home Assistant area/attic is also linked to loft"
             }
           ] =
             snapshot
             |> Audit.issues()
             |> Audit.issues_for(:locations, "attic")
  end
end
