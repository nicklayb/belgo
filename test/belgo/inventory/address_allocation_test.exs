defmodule Belgo.Inventory.AddressAllocationTest do
  use ExUnit.Case, async: true

  alias Belgo.Fixtures
  alias Belgo.Inventory.AddressAllocation
  alias Belgo.Inventory.AddressRange
  alias Belgo.Inventory.Codec

  @iot_range %AddressRange{name: "IoT", start: "10.0.0.20", end: "10.0.0.30", kind: :iot}

  setup do
    snapshot = Fixtures.snapshot()

    networks =
      Enum.map(snapshot.networks, &%{&1 | ranges: [@iot_range]})

    %{snapshot: %{snapshot | networks: networks}}
  end

  test "suggests the first address of the kind's range nothing uses", %{snapshot: snapshot} do
    # The TV of the living room has 10.0.0.20; a provider reported 10.0.0.21.
    used =
      AddressAllocation.used_addresses(
        snapshot,
        [
          %Belgo.Discovery.Observation{
            provider: :opnsense,
            source: :kea_reservation,
            kind: :device,
            ip: "10.0.0.21"
          }
        ],
        nil
      )

    assert %AddressAllocation.Suggestion{
             ip: "10.0.0.22",
             network_id: "springfield",
             range: @iot_range
           } =
             AddressAllocation.suggest(snapshot, :iot, used)

    assert nil == AddressAllocation.suggest(snapshot, :server, used)
  end

  test "the edited device's own addresses are free for it", %{snapshot: snapshot} do
    used = AddressAllocation.used_addresses(snapshot, [], "tv-living-room")
    assert %{ip: "10.0.0.20"} = AddressAllocation.suggest(snapshot, :iot, used)
  end

  test "a full range suggests nothing, network and broadcast addresses are never suggested",
       %{snapshot: snapshot} do
    used = MapSet.new(Enum.map(20..30, &"10.0.0.#{&1}"))
    assert nil == AddressAllocation.suggest(snapshot, :iot, used)

    edge = %AddressRange{name: "Edge", start: "10.0.0.255", end: "10.0.0.255", kind: :iot}
    snapshot = %{snapshot | networks: Enum.map(snapshot.networks, &%{&1 | ranges: [edge]})}
    assert nil == AddressAllocation.suggest(snapshot, :iot, MapSet.new())
  end

  test "interfaces outside the kind's ranges are offered distinct free addresses", %{
    snapshot: snapshot
  } do
    interfaces = [
      %Belgo.Inventory.Interface{ip: "10.0.0.143"},
      %Belgo.Inventory.Interface{ip: "10.0.0.25"},
      %Belgo.Inventory.Interface{ip: nil}
    ]

    assert %{0 => %{ip: "10.0.0.20"}, 2 => %{ip: "10.0.0.21"}} =
             suggestions =
             AddressAllocation.suggest_interfaces(snapshot, :iot, interfaces, MapSet.new())

    assert %{} ==
             AddressAllocation.suggest_interfaces(
               snapshot,
               :iot,
               [%Belgo.Inventory.Interface{ip: "10.0.5.4", network_id: "shelbyville"}],
               MapSet.new()
             )

    # 10.0.0.25 is already in the IoT range: nothing offered.
    refute Map.has_key?(suggestions, 1)

    assert %{} ==
             AddressAllocation.suggest_interfaces(snapshot, :server, interfaces, MapSet.new())
  end

  describe "form params" do
    test "choosing a kind fills interfaces without address or outside its range", %{
      snapshot: snapshot
    } do
      params = %{
        "kind" => "iot",
        "interfaces" => %{
          "0" => %{"mac" => "02:00:00:00:09:01", "ip" => "10.0.0.143", "assignment" => "dynamic"},
          "1" => %{"ip" => "10.0.0.25", "assignment" => "static"}
        }
      }

      {params, suggestions} =
        AddressAllocation.suggest_params(params, :other, snapshot, MapSet.new(["10.0.0.20"]))

      assert %{"ip" => "10.0.0.21", "network_id" => "springfield", "assignment" => "reserved"} =
               params["interfaces"]["0"]

      # Already in the IoT range: kept.
      assert "10.0.0.25" == params["interfaces"]["1"]["ip"]
      assert [0] == Map.keys(suggestions)
    end

    test "an added interface gets the next free address", %{snapshot: snapshot} do
      params = %{
        "kind" => "iot",
        "interfaces_sort" => ["0", "new"],
        "interfaces" => %{"0" => %{"ip" => "10.0.0.21", "assignment" => "static"}}
      }

      {params, suggestions} =
        AddressAllocation.suggest_params(params, :iot, snapshot, MapSet.new(["10.0.0.20"]))

      assert ["0", "1"] == params["interfaces_sort"]
      assert %{"ip" => "10.0.0.22"} = params["interfaces"]["1"]
      assert %{1 => %{ip: "10.0.0.22"}} = suggestions
    end

    test "nothing changes without a new kind or a new interface", %{snapshot: snapshot} do
      params = %{"kind" => "iot", "interfaces" => %{"0" => %{"ip" => ""}}}

      assert {^params, %{}} =
               AddressAllocation.suggest_params(params, :iot, snapshot, MapSet.new())
    end
  end

  describe "network ranges" do
    test "must belong to the network and not overlap" do
      assert {:error, changeset} =
               Codec.decode(:networks, %{
                 "id" => "springfield",
                 "name" => "Springfield",
                 "cidr" => "10.0.0.0/24",
                 "ranges" => [
                   %{"name" => "Servers", "start" => "10.0.0.10", "end" => "10.0.0.20"},
                   %{
                     "name" => "IoT",
                     "start" => "10.0.0.15",
                     "end" => "10.0.0.30",
                     "kind" => "iot"
                   },
                   %{"name" => "Shelbyville", "start" => "10.0.5.1", "end" => "10.0.5.9"}
                 ]
               })

      messages = Enum.map(Keyword.get_values(changeset.errors, :ranges), &elem(&1, 0))
      assert "Shelbyville must belong to 10.0.0.0/24" in messages
      assert "Servers and IoT overlap" in messages
    end

    test "are stored with the network" do
      network = Fixtures.network(ranges: [@iot_range])

      assert %{
               "ranges" => [
                 %{"name" => "IoT", "start" => "10.0.0.20", "end" => "10.0.0.30", "kind" => "iot"}
               ]
             } =
               Codec.encode(network)

      assert {:ok, %{ranges: [@iot_range]}} = Codec.decode(:networks, Codec.encode(network))
    end
  end
end
