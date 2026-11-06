defmodule Belgo.Discovery.Report do
  @moduledoc "Everything one provider reported during one discovery."

  alias Belgo.Discovery.Observation

  @enforce_keys [:provider, :observations]
  defstruct [:provider, :observations, counts: %{}, failures: []]

  @type t :: %__MODULE__{
          provider: atom(),
          observations: [Observation.t()],
          counts: %{atom() => non_neg_integer()},
          failures: [{atom(), any()}]
        }

  @doc """
  Builds a report, counting observations by source for logs and the UI. `failures`
  lists the parts of the provider that could not be read.
  """
  @spec new(atom(), [Observation.t()], [{atom(), any()}]) :: t()
  def new(provider, observations, failures \\ []) do
    %__MODULE__{
      provider: provider,
      observations: observations,
      counts: Enum.frequencies_by(observations, & &1.source),
      failures: failures
    }
  end
end
