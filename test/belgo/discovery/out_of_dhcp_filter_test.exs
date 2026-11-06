defmodule Belgo.Discovery.OutOfDhcpFilterTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Correlation.DiscoveredDevice
  alias Belgo.Discovery.Observation
  alias Belgo.Discovery.OutOfDhcpFilter

  defp discovered(id, provider, attributes) do
    observation = %Observation{provider: provider, source: :kea_reservation, kind: :device}
    struct!(%DiscoveredDevice{id: id, observations: [observation]}, attributes)
  end

  defp devices do
    [
      discovered("moe", :opnsense, hostname: "moe-pc", ips: ["10.0.0.100"]),
      discovered("apu", :adguard, hostname: "apu-laptop", ips: ["10.0.0.9"])
    ]
  end

  defp ids(filter), do: Enum.map(OutOfDhcpFilter.apply_filter(devices(), filter), & &1.id)

  test "sorts by address ascending by default, defaults stay out of the query string" do
    filter = OutOfDhcpFilter.new(%{})

    assert ["apu", "moe"] == ids(filter)
    assert %{} == OutOfDhcpFilter.to_query_params(filter)
  end

  test "round trips through the query string" do
    filter =
      %{}
      |> OutOfDhcpFilter.new()
      |> OutOfDhcpFilter.sort_by(:device)
      |> OutOfDhcpFilter.sort_by(:device)
      |> OutOfDhcpFilter.update(%{"provider" => "opnsense", "query" => "10.0"})

    params = OutOfDhcpFilter.to_query_params(filter)

    assert %{
             "sort" => "device",
             "direction" => "desc",
             "provider" => "opnsense",
             "query" => "10.0"
           } ==
             params

    assert filter == OutOfDhcpFilter.new(params)
    assert ["moe"] == ids(filter)
  end

  test "invalid sort values fall back to the defaults" do
    assert %{sort: :address, direction: :asc} =
             OutOfDhcpFilter.new(%{"sort" => "bogus", "direction" => "sideways"})
  end
end
