defmodule Belgo.Sync.PushReport do
  @moduledoc """
  Outcome of a push to one provider: the applied operations, the entries that could
  not be written and the parts of the provider that failed (one failing service never
  blocks the others).
  """

  @enforce_keys [:provider, :operations, :skipped]
  defstruct [:provider, :operations, :skipped, failures: []]

  @type t :: %__MODULE__{
          provider: atom(),
          operations: [struct()],
          skipped: [String.t()],
          failures: [{atom(), any()}]
        }

  @doc "One line describing the push, for logs and the UI."
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{operations: [], failures: [_ | _]} = report),
    do: "nothing written" <> skips(report.skipped)

  def summary(%__MODULE__{operations: [], skipped: skipped}),
    do: "already up to date" <> skips(skipped)

  def summary(%__MODULE__{operations: operations, skipped: skipped}) do
    Enum.map_join(operations, "; ", & &1.summary) <> skips(skipped)
  end

  defp skips([]), do: ""
  defp skips(skipped), do: " (skipped: " <> Enum.join(skipped, "; ") <> ")"
end
