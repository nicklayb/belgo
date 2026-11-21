defmodule Belgo.Providers.Prometheus.Client do
  @moduledoc "Behaviour of the Prometheus query API access, so tests never reach the network."

  alias Belgo.Providers.Prometheus.Config

  @doc """
  Runs an instant PromQL query and returns the `data.result` samples of its vector,
  each a map with `"metric"` (labels) and `"value"`.
  """
  @callback query(Config.t(), promql :: String.t()) :: {:ok, [map()]} | {:error, any()}
end
