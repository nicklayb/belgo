defmodule Belgo.Topology.WorkloadTree do
  @moduledoc """
  What runs on a host as a shallow tree: workloads sharing a group (the application
  of a pod, the Compose project of a container) are nested under that group, others
  stay at the top level. Groups come first, sorted by name (then namespace), then the
  ungrouped workloads, sorted by name. Pure, rebuilt from live workloads.
  """

  alias Belgo.Discovery.Workload

  defmodule Group do
    @moduledoc """
    Workloads of one application on a host: `name` is the group (application or
    Compose project), `namespace` the Kubernetes namespace (`nil` for containers).
    """
    @enforce_keys [:name]
    defstruct [:name, :namespace, workloads: []]

    @type t :: %__MODULE__{
            name: String.t(),
            namespace: String.t() | nil,
            workloads: [Workload.t()]
          }
  end

  @type entry :: Group.t() | Workload.t()

  @doc """
  Builds the entries of a host from its workloads: `Group`s first, then the
  workloads without group.
  """
  @spec build([Workload.t()]) :: [entry()]
  def build(workloads) do
    {grouped, ungrouped} = Enum.split_with(workloads, &grouped?/1)

    groups =
      grouped
      |> Enum.group_by(&{&1.namespace, &1.group})
      |> Enum.map(fn {{namespace, name}, members} ->
        %Group{name: name, namespace: namespace, workloads: sort_workloads(members)}
      end)
      |> Enum.sort_by(&sort_key(&1.name, &1.namespace))

    groups ++ sort_workloads(ungrouped)
  end

  @doc """
  Returns `true` when a workload belongs to a group. A pod whose group is its own
  name (a bare pod, without owner) is not grouped.
  """
  @spec grouped?(Workload.t()) :: boolean()
  def grouped?(%Workload{group: group, name: name}), do: group not in [nil, ""] and group != name

  @doc "Counts the workloads of entries, nested ones included."
  @spec workload_count([entry()]) :: non_neg_integer()
  def workload_count(entries) do
    Enum.reduce(entries, 0, fn
      %Group{workloads: workloads}, count -> count + length(workloads)
      %Workload{}, count -> count + 1
    end)
  end

  defp sort_workloads(workloads),
    do: Enum.sort_by(workloads, &sort_key(&1.name, &1.namespace))

  defp sort_key(name, namespace), do: {String.downcase(name), name, namespace || ""}
end
