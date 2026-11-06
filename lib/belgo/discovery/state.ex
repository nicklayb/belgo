defmodule Belgo.Discovery.State do
  @moduledoc "What the UI sees of the discovery: provider statuses and the correlation."

  alias Belgo.Discovery.Correlation
  alias Belgo.Discovery.Observation
  alias Belgo.Discovery.Report
  alias Belgo.Providers.Settings

  defmodule ProviderStatus do
    @moduledoc "Outcome of the last pull and the last push of one provider."
    @enforce_keys [:key, :label]
    defstruct [:key, :label, :mode, :report, :error, :completed_at, :last_push, running?: false]

    @type push :: %{
            device_id: String.t(),
            result: {:ok, Belgo.Sync.PushReport.t()} | {:error, any()},
            completed_at: DateTime.t()
          }
    @type t :: %__MODULE__{
            key: atom(),
            label: String.t(),
            mode: :read | :write,
            report: Report.t() | nil,
            error: any(),
            completed_at: DateTime.t() | nil,
            last_push: push() | nil,
            running?: boolean()
          }
  end

  defstruct providers: [], settings_errors: [], correlation: %Correlation{}

  @type t :: %__MODULE__{
          providers: [ProviderStatus.t()],
          settings_errors: [String.t()],
          correlation: Correlation.t()
        }

  @doc "Keeps the statuses of providers still configured and adds the new ones."
  @spec configure(t(), Settings.t()) :: t()
  def configure(%__MODULE__{} = state, %Settings{configs: configs}) do
    status_by_key = Map.new(state.providers, &{&1.key, &1})

    providers =
      Enum.map(configs, fn %Settings.Configured{module: module, mode: mode} ->
        status =
          Map.get(status_by_key, module.key(), %ProviderStatus{
            key: module.key(),
            label: module.label()
          })

        %{status | mode: mode}
      end)

    %__MODULE__{state | providers: providers, settings_errors: []}
  end

  @doc "Records invalid settings, keeping the previous providers."
  @spec put_settings_error(t(), [String.t()]) :: t()
  def put_settings_error(%__MODULE__{} = state, messages),
    do: %__MODULE__{state | settings_errors: messages}

  @doc "Marks a provider as being pulled."
  @spec start(t(), atom()) :: t()
  def start(%__MODULE__{} = state, key),
    do:
      update_provider(state, key, fn %ProviderStatus{} = status -> %{status | running?: true} end)

  @doc "Records the result of a pull. A failure keeps the previous report."
  @spec complete(t(), atom(), {:ok, Report.t()} | {:error, any()}, DateTime.t()) :: t()
  def complete(%__MODULE__{} = state, key, result, completed_at) do
    update_provider(state, key, fn %ProviderStatus{} = status ->
      status = %{status | running?: false, completed_at: completed_at}

      case result do
        {:ok, report} -> %{status | report: report, error: nil}
        {:error, reason} -> %{status | error: reason}
      end
    end)
  end

  @doc "Records the result of a push of one device."
  @spec complete_push(t(), atom(), String.t(), {:ok, any()} | {:error, any()}, DateTime.t()) ::
          t()
  def complete_push(%__MODULE__{} = state, key, device_id, result, completed_at) do
    push = %{device_id: device_id, result: result, completed_at: completed_at}
    update_provider(state, key, fn %ProviderStatus{} = status -> %{status | last_push: push} end)
  end

  @doc "Stores the correlation."
  @spec put_correlation(t(), Correlation.t()) :: t()
  def put_correlation(%__MODULE__{} = state, correlation),
    do: %__MODULE__{state | correlation: correlation}

  @doc "Lists the observations of every provider's last successful report."
  @spec observations(t()) :: [Observation.t()]
  def observations(%__MODULE__{providers: providers}) do
    Enum.flat_map(providers, fn
      %ProviderStatus{report: %Report{observations: observations}} -> observations
      _never_succeeded -> []
    end)
  end

  defp update_provider(%__MODULE__{} = state, key, function) do
    %__MODULE__{
      state
      | providers: Enum.map(state.providers, &if(&1.key == key, do: function.(&1), else: &1))
    }
  end
end
