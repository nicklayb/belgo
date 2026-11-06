defmodule Belgo.Inventory.NetworkTest do
  use ExUnit.Case, async: true

  alias Belgo.Inventory.Network

  @springfield %{"name" => "Springfield", "cidr" => "10.0.0.0/24"}

  defp errors(params) do
    %Network{}
    |> Network.changeset(Map.merge(@springfield, params))
    |> Ecto.Changeset.traverse_errors(fn {message, options} ->
      Regex.replace(~r"%{(\w+)}", message, fn _match, key ->
        to_string(options[String.to_existing_atom(key)])
      end)
    end)
  end

  test "the DHCP range needs both bounds, inside the network, in order" do
    assert %{} == errors(%{"dhcp_start" => "10.0.0.100", "dhcp_end" => "10.0.0.199"})

    assert %{dhcp_end: ["is required with the start of the range"]} ==
             errors(%{"dhcp_start" => "10.0.0.100"})

    assert %{dhcp_end: ["must belong to 10.0.0.0/24"]} ==
             errors(%{"dhcp_start" => "10.0.0.100", "dhcp_end" => "10.0.1.5"})

    assert %{dhcp_end: ["must come after the start of the range"]} ==
             errors(%{"dhcp_start" => "10.0.0.100", "dhcp_end" => "10.0.0.20"})
  end

  test "in_dhcp_range?/2 checks the bounds, inclusive" do
    network = %Network{cidr: "10.0.0.0/24", dhcp_start: "10.0.0.100", dhcp_end: "10.0.0.199"}

    assert Network.in_dhcp_range?(network, "10.0.0.100")
    assert Network.in_dhcp_range?(network, "10.0.0.199")
    refute Network.in_dhcp_range?(network, "10.0.0.50")
    refute Network.in_dhcp_range?(%Network{cidr: "10.0.0.0/24"}, "10.0.0.150")
  end
end
