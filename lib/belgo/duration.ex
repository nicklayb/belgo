defmodule Belgo.Duration do
  @moduledoc "Parses human durations of the configuration files: `30s`, `15m`, `1h` or seconds."

  @format ~r/\A(?<amount>\d+)\s*(?<unit>s|m|h)?\z/
  @milliseconds_by_unit %{"s" => 1_000, "m" => 60_000, "h" => 3_600_000}
  @default_unit "s"

  @doc "Returns the duration in milliseconds; integers are seconds."
  @spec parse(any()) :: {:ok, non_neg_integer()} | :error
  def parse(seconds) when is_integer(seconds) and seconds >= 0, do: parse("#{seconds}s")

  def parse(value) when is_binary(value) do
    case Regex.named_captures(@format, String.trim(value)) do
      %{"amount" => amount, "unit" => unit} ->
        unit = if unit == "", do: @default_unit, else: unit
        {:ok, String.to_integer(amount) * Map.fetch!(@milliseconds_by_unit, unit)}

      nil ->
        :error
    end
  end

  def parse(_value), do: :error
end
