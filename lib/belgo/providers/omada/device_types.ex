defmodule Belgo.Providers.Omada.DeviceTypes do
  @moduledoc """
  Maps Belgo device kinds to Omada client types and back. Pure functions only.

  Omada offers its client types through `GET /openapi/v1/{omadacId}/correction-list`
  (`typeList` entries with `name` and `key`); the list itself is not documented. Each
  kind therefore lists candidates, and the first one the controller offers (key or
  name, case insensitive) wins: a candidate the controller does not know is never
  sent. `Sensor` (category `Smart Home`) was measured on the owner's controller.
  """

  @candidates_by_kind [
    server: ["Server", "PC"],
    workstation: ["PC", "Desktop", "Computer"],
    laptop: ["Laptop", "PC"],
    phone: ["Phone", "Smartphone", "Android", "iPhone"],
    tablet: ["Tablet", "Pad", "iPad"],
    media: ["TV", "Smart TV", "Media Player", "Speaker"],
    gaming: ["Game Console", "Console", "Gaming"],
    iot: ["Sensor", "Smart Home", "IoT"],
    network: ["Router", "Switch", "Access Point", "Network Device"],
    printer: ["Printer"],
    camera: ["Camera", "IP Camera", "IPC"],
    appliance: ["Appliance", "Smart Appliance"]
  ]

  @doc "Omada type names tried, in order, for a Belgo kind (none for `other`)."
  @spec candidates(atom()) :: [String.t()]
  def candidates(kind), do: Keyword.get(@candidates_by_kind, kind, [])

  @doc """
  The Omada type to send for a kind: the `key` (else `name`) of the first entry of
  the controller's `types` matching a candidate, `nil` when none does.
  """
  @spec to_omada(atom(), [map()]) :: String.t() | nil
  def to_omada(kind, types) when is_list(types) do
    Enum.find_value(candidates(kind), fn candidate ->
      Enum.find_value(types, &matching_value(&1, candidate))
    end)
  end

  def to_omada(_kind, _types), do: nil

  @doc "The Belgo kind of the first Omada value (type, then category) that maps to one."
  @spec to_kind([String.t() | nil]) :: atom() | nil
  def to_kind(values), do: Enum.find_value(values, &kind_of/1)

  defp kind_of(value) when is_binary(value) do
    Enum.find_value(@candidates_by_kind, fn {kind, candidates} ->
      if Enum.any?(candidates, &same?(&1, value)), do: kind
    end)
  end

  defp kind_of(_value), do: nil

  defp matching_value(%{} = type, candidate) do
    if same?(type["key"], candidate) or same?(type["name"], candidate),
      do: type["key"] || type["name"]
  end

  defp matching_value(_type, _candidate), do: nil

  defp same?(left_value, right_value) when is_binary(left_value) and is_binary(right_value),
    do: String.downcase(left_value) == String.downcase(right_value)

  defp same?(_left_value, _right_value), do: false
end
