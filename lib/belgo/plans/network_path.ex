defmodule Belgo.Plans.NetworkPath do
  @moduledoc """
  The lines the 3D plan draws for a device's network path (`Belgo.Topology.Routing.path/3`):
  one segment between each pair of consecutive hops placed on the plan. A segment is
  `:wired` or `:wireless` after the link of its lower hop, or `:indirect` when hops
  missing from the plan (or unknown to Belgo) lie in between. Pure functions.
  """

  alias Belgo.Topology.Routing.Hop

  @type segment :: %{from: String.t(), to: String.t(), kind: :wired | :wireless | :indirect}

  @doc "Segments between the hops placed on the plan (`placed_device_ids`), device first."
  @spec segments([Hop.t()], MapSet.t(String.t())) :: [segment()]
  def segments(hops, placed_device_ids) do
    {segments, _previous} =
      Enum.reduce(hops, {[], nil}, fn hop, {segments, previous} ->
        cond do
          not placed?(hop, placed_device_ids) ->
            {segments, mark_skipped(previous)}

          is_nil(previous) ->
            {segments, {hop, false}}

          true ->
            {[segment(previous, hop) | segments], {hop, false}}
        end
      end)

    Enum.reverse(segments)
  end

  @doc "Ids of the devices of the path that are not on the plan."
  @spec unplaced_device_ids([Hop.t()], MapSet.t(String.t())) :: MapSet.t(String.t())
  def unplaced_device_ids(hops, placed_device_ids) do
    for %Hop{device: %{id: id}} <- hops,
        not MapSet.member?(placed_device_ids, id),
        into: MapSet.new(),
        do: id
  end

  defp placed?(%Hop{device: %{id: id}}, placed_device_ids),
    do: MapSet.member?(placed_device_ids, id)

  defp placed?(%Hop{}, _placed_device_ids), do: false

  defp mark_skipped(nil), do: nil
  defp mark_skipped({hop, _skipped?}), do: {hop, true}

  defp segment({previous, skipped?}, hop),
    do: %{from: previous.device.id, to: hop.device.id, kind: kind(previous, skipped?)}

  defp kind(_previous, true), do: :indirect
  defp kind(%Hop{link: %{wireless?: true}}, false), do: :wireless
  defp kind(_previous, false), do: :wired
end
