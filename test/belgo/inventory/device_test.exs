defmodule Belgo.Inventory.DeviceTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Device

  defp changeset(params), do: Device.changeset(%Device{}, params)

  test "derives the identifier from the name and normalises values" do
    changeset =
      changeset(%{
        "name" => "Mr. Burns' Node",
        "hostname" => "Burns",
        "tags" => "nuclear, plant, ,nuclear",
        "interfaces" => [%{"mac" => "02-00-00-00-07-42", "ip" => "10.0.0.42"}],
        "location_id" => "basement"
      })

    assert changeset.valid?
    device = Ecto.Changeset.apply_changes(changeset)
    assert "mr-burns-node" == device.id
    assert "burns" == device.hostname
    assert ["nuclear", "plant"] == device.tags
    assert [%{mac: "02:00:00:00:07:42", assignment: :reserved}] = device.interfaces
    assert :location == Device.placement_mode(device)
    assert nil == device.placement
  end

  test "switches keep their number of ports and PoE, other devices never do" do
    switch_params = %{
      "name" => "Plow King",
      "network_role" => "switch",
      "port_count" => "8",
      "poe" => "true"
    }

    switch = Ecto.Changeset.apply_changes(changeset(switch_params))

    assert %Device{kind: :network, port_count: 8, poe: true} = switch
    assert Device.poe?(switch)

    access_point =
      Ecto.Changeset.apply_changes(changeset(%{switch_params | "network_role" => "access_point"}))

    assert %Device{port_count: nil, poe: false} = access_point
    refute Device.poe?(%Device{poe: true})

    assert %{port_count: [_must_be_positive]} =
             errors(changeset(%{switch_params | "port_count" => "0"}))
  end

  test "rejects contradicting placements coming from files" do
    changeset = changeset(%{"name" => "Krusty", "location_id" => "basement", "portable" => true})

    assert %{placement: ["only one of location, host or portable can be set"]} = errors(changeset)
  end

  test "a placement chosen in a form clears the other fields" do
    device = %Device{id: "itchy", name: "Itchy", location_id: "basement"}

    changeset =
      Device.changeset(device, %{
        "placement" => "host",
        "host_id" => "smithers",
        "virtualization" => "container"
      })

    assert changeset.valid?

    assert {:host, "smithers"} ==
             changeset
             |> Ecto.Changeset.apply_changes()
             |> Device.placement()
  end

  test "guests require a virtualisation and cannot host themselves" do
    changeset = changeset(%{"name" => "Itchy", "placement" => "host", "host_id" => "itchy"})

    assert %{virtualization: ["can't be blank"], host_id: ["cannot be the device itself"]} =
             errors(changeset)
  end

  test "reserved interfaces need both a MAC and an IP" do
    changeset = changeset(%{"name" => "Scratchy", "interfaces" => [%{"ip" => "10.0.0.5"}]})

    assert %{interfaces: [%{mac: ["can't be blank"]}]} = errors(changeset)
  end

  test "hostname defaults to the identifier" do
    assert "itchy" == Device.hostname(%Device{id: "itchy"})
    assert "scratchy" == Device.hostname(%Device{id: "itchy", hostname: "scratchy"})
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _options} -> message end)
  end

  test "interfaces normalise their DNS names and need an address for them" do
    changeset =
      changeset(%{
        "name" => "Kwik-E-Mart",
        "interfaces" => [
          %{"assignment" => "dynamic", "dns_names" => "Squishee, apu.example, , squishee"}
        ]
      })

    assert %{interfaces: [%{dns_names: ["require an IP address"]}]} = errors(changeset)

    assert [%{dns_names: ["squishee", "apu.example"]}] =
             Ecto.Changeset.apply_changes(changeset).interfaces

    invalid =
      changeset(%{
        "name" => "Kwik-E-Mart",
        "interfaces" => [
          %{"assignment" => "static", "ip" => "10.0.0.5", "dns_names" => "bad_name"}
        ]
      })

    assert %{interfaces: [%{dns_names: ["invalid names: bad_name"]}]} = errors(invalid)
  end

  test "metadata entries need a label and a value, labels are unique" do
    valid =
      changeset(%{
        "name" => "Duff Fridge",
        "metadata" => [%{"label" => " Brand ", "value" => "Duff"}]
      })

    assert [%{label: "Brand", value: "Duff"}] = Ecto.Changeset.apply_changes(valid).metadata

    assert %{metadata: [%{value: ["can't be blank"]}]} =
             errors(
               changeset(%{
                 "name" => "Duff Fridge",
                 "metadata" => [%{"label" => "Brand", "value" => ""}]
               })
             )

    duplicated =
      changeset(%{
        "name" => "Duff Fridge",
        "metadata" => [
          %{"label" => "Brand", "value" => "Duff"},
          %{"label" => "brand", "value" => "Fudd"}
        ]
      })

    assert %{metadata: ["each label can only be used once"]} = errors(duplicated)
  end
end
