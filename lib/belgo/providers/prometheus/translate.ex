defmodule Belgo.Providers.Prometheus.Translate do
  @moduledoc """
  Builds the PromQL queries and turns their samples into workloads. Pure functions.

  Pods come from kube-state-metrics: `kube_pod_info` (namespace, pod, node,
  `created_by_kind` / `created_by_name`), `kube_pod_status_phase == 1` (phase),
  `kube_replicaset_owner` (the Deployment of a ReplicaSet), `kube_pod_labels`
  (`label_app_kubernetes_io_instance`, only exported when kube-state-metrics
  allowlists it) and `kube_node_info` (`internal_ip` of each node).

  Docker containers come from cAdvisor: `container_last_seen` series with a `name`
  and an `image`, without `pod` (those are Kubernetes containers seen by the
  kubelet). The scrape target (`instance`) is the host.
  """

  alias Belgo.Discovery.Workload
  alias Belgo.Discovery.Workload.HostReference

  @provider :prometheus
  @replica_set_kind "ReplicaSet"
  @instance_label "label_app_kubernetes_io_instance"
  @compose_project_label "container_label_com_docker_compose_project"
  @running_status "running"

  @doc "PromQL queries of the pod part, by name, limited to `namespaces` (`nil`: all)."
  @spec pod_queries([String.t()] | nil) :: %{atom() => String.t()}
  def pod_queries(namespaces) do
    selector = namespace_selector(namespaces)

    %{
      pods: "kube_pod_info#{selector}",
      phases: "kube_pod_status_phase#{selector} == 1",
      replica_sets: "kube_replicaset_owner#{selector}",
      labels: "kube_pod_labels#{selector}",
      nodes: "kube_node_info"
    }
  end

  @doc "PromQL query of the Docker containers seen by cAdvisor."
  @spec container_query() :: String.t()
  def container_query, do: ~s|container_last_seen{name!="",image!="",pod=""}|

  @doc """
  Turns the samples of `pod_queries/1` (same keys) into pod workloads, hosted on their
  node (named by the node, with its internal IP).
  """
  @spec pods(%{atom() => [map()]}) :: [Workload.t()]
  def pods(samples) do
    ip_by_node = index(samples.nodes, ["node"], "internal_ip")
    phase_by_pod = index(samples.phases, ["namespace", "pod"], "phase")

    deployment_by_replica_set =
      index(samples.replica_sets, ["namespace", "replicaset"], "owner_name")

    instance_by_pod = index(samples.labels, ["namespace", "pod"], @instance_label)

    samples.pods
    |> Enum.map(&Map.get(&1, "metric", %{}))
    |> Enum.filter(&(present?(&1["pod"]) and present?(&1["node"])))
    |> Enum.uniq_by(&{&1["namespace"], &1["pod"]})
    |> Enum.map(fn labels ->
      key = {labels["namespace"], labels["pod"]}
      node = labels["node"]

      %Workload{
        provider: @provider,
        source: :kube_pod,
        kind: :pod,
        name: labels["pod"],
        reference: "#{labels["namespace"]}/#{labels["pod"]}",
        namespace: labels["namespace"],
        group:
          Map.get(instance_by_pod, key) ||
            owner_name(labels, deployment_by_replica_set) || labels["pod"],
        status: Map.get(phase_by_pod, key),
        host: %HostReference{name: node, ips: List.wrap(Map.get(ip_by_node, {node}))}
      }
    end)
  end

  @doc """
  Turns `container_query/0` samples into container workloads. `device_by_instance`
  names the inventory device of a scrape target (`instance`, e.g. `cadvisor:8080`
  inside a Compose network), else the target's host name is matched.
  """
  @spec containers([map()], %{String.t() => String.t()}) :: [Workload.t()]
  def containers(samples, device_by_instance) do
    samples
    |> Enum.map(&Map.get(&1, "metric", %{}))
    |> Enum.filter(&(present?(&1["name"]) and present?(&1["instance"])))
    |> Enum.uniq_by(&{&1["instance"], &1["name"]})
    |> Enum.map(fn labels ->
      instance = labels["instance"]
      host_name = instance_host(instance)

      %Workload{
        provider: @provider,
        source: :docker_container,
        kind: :container,
        name: labels["name"],
        reference: "#{instance}/#{labels["name"]}",
        image: labels["image"],
        group: blank_to_nil(labels[@compose_project_label]),
        status: @running_status,
        host: %HostReference{
          name: host_name,
          device_id:
            Map.get(device_by_instance, instance) || Map.get(device_by_instance, host_name),
          ips: if(ip_address?(host_name), do: [host_name], else: [])
        }
      }
    end)
  end

  @doc "Host part of a scrape target (`skynet.home.lan:8081` gives `skynet.home.lan`)."
  @spec instance_host(String.t()) :: String.t()
  def instance_host(instance) do
    case URI.parse("//" <> instance) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _unparsable -> instance
    end
  end

  defp owner_name(%{"created_by_kind" => @replica_set_kind} = labels, deployment_by_replica_set) do
    Map.get(deployment_by_replica_set, {labels["namespace"], labels["created_by_name"]}) ||
      labels["created_by_name"]
  end

  defp owner_name(labels, _deployment_by_replica_set), do: blank_to_nil(labels["created_by_name"])

  defp namespace_selector(nil), do: ""
  defp namespace_selector([]), do: ""

  defp namespace_selector(namespaces),
    do: ~s|{namespace=~"#{Enum.join(namespaces, "|")}"}|

  # Maps the values of `key_labels` (as a tuple) to the `value_label` of each sample.
  defp index(samples, key_labels, value_label) do
    for %{"metric" => labels} <- samples,
        value = labels[value_label],
        present?(value),
        into: %{},
        do: {List.to_tuple(Enum.map(key_labels, &labels[&1])), value}
  end

  defp ip_address?(value), do: match?({:ok, _address}, :inet.parse_address(to_charlist(value)))

  defp present?(value), do: is_binary(value) and value != ""

  defp blank_to_nil(value), do: if(present?(value), do: value)
end
