defmodule Belgo.SearchTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Correlation
  alias Belgo.Fixtures
  alias Belgo.Providers.Opnsense
  alias Belgo.Search

  defp search(query, options \\ []), do: Search.run(Fixtures.snapshot(), query, options)

  defp hits(query, options \\ []),
    do: Enum.map(search(query, options), &{&1.id, &1.field, &1.value})

  test "finds devices by name, hostname, IP, DNS name, location, tag and metadata" do
    assert [{"burns-node", "Name", "Burns Node"} | _rest] = hits("burns")
    assert [{"smithers", "IP", "10.0.0.11"}] = hits("10.0.0.11")
    assert [{"smithers", "DNS name", "assistant"}] = hits("assistant")
    assert [{"burns-node", "Serial number", "SN-1895-MB"}] = hits("1895")

    assert {"tv-living-room", "Location", "742 Evergreen Terrace / Living Room"} in hits(
             "evergreen"
           )
  end

  test "MAC addresses match with or without separators" do
    assert [{"burns-node", "MAC", "02:00:00:00:00:10"}] = hits("02-00-00-00-00-10")
    assert [{"burns-node", "MAC", "02:00:00:00:00:10"}] = hits("020000000010")
  end

  test "exact matches come first" do
    assert [%Search.Result{id: "plow-king", score: 0} | _rest] = search("plow king")
  end

  test "an empty query finds nothing" do
    assert [] == search("  ")
  end

  test "discovered devices are only included on demand" do
    {:ok, report} =
      Opnsense.discover(%Opnsense.Config{
        url: "https://opnsense",
        api_key: "k",
        api_secret: "s",
        client: Belgo.Fixtures.OpnsenseClient
      })

    correlation = Correlation.build(Fixtures.snapshot(), report.observations)

    assert [] == search("moe-pc")

    assert [%Search.Result{type: :discovered, id: "mac-02-00-00-00-05-01", title: "moe-pc"}] =
             search("moe-pc", discovery: correlation)

    {:ok, moe} = Correlation.fetch_device(correlation, "mac-02-00-00-00-05-01")
    assert Search.discovered_match?(moe, "05:01")
    refute Search.discovered_match?(moe, "nelson")
    assert Search.discovered_match?(moe, "")
  end
end
