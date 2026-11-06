defmodule Belgo.Fixtures.Pinger do
  @moduledoc "Ping without network: Burns Node (10.0.0.10) answers, nothing else does."

  @answering_address "10.0.0.10"

  @doc "Answers like `Belgo.Reachability.Pinger.ping/2`."
  @spec ping(String.t(), pos_integer()) :: :up | :down
  def ping(@answering_address, _timeout), do: :up
  def ping(_address, _timeout), do: :down
end
