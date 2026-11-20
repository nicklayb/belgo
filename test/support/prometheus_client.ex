defmodule Belgo.Fixtures.PrometheusClient do
  @moduledoc """
  Prometheus client answering Springfield samples. The node `springfield-k8s` (IP
  of Smithers) runs eleven `nuclear-plant` pods (Deployment through a ReplicaSet)
  and `krusty-0` (StatefulSet, labelled `krusty-show`), plus ten bare pods
  `bart-prank-NN` (no owner). cAdvisor sees `duff-brewery`
  on Smithers and `itchy-scratchy` behind `cadvisor:8080`. The `broken.example`
  instance fails every query; `pods-broken.example` fails the pod queries only.
  """

  @behaviour Belgo.Providers.Prometheus.Client

  @nuclear_plant_pod_count 11
  @bare_pod_count 10

  @impl Belgo.Providers.Prometheus.Client
  def query(%{url: "https://broken.example"}, _promql), do: {:error, {:http_status, "/", 502, ""}}

  def query(%{url: "https://pods-broken.example"}, "kube_" <> _rest),
    do: {:error, {:http_status, "/", 500, ""}}

  def query(_config, "kube_pod_info" <> _selector), do: {:ok, pods()}
  def query(_config, "kube_pod_status_phase" <> _selector), do: {:ok, phases()}
  def query(_config, "kube_replicaset_owner" <> _selector), do: {:ok, replica_sets()}
  def query(_config, "kube_pod_labels" <> _selector), do: {:ok, labels()}
  def query(_config, "kube_node_info"), do: {:ok, nodes()}
  def query(_config, "container_last_seen" <> _selector), do: {:ok, containers()}

  @doc "`kube_pod_info` samples."
  def pods do
    plant_pods =
      for index <- 1..@nuclear_plant_pod_count do
        sample(%{
          "namespace" => "sector-7g",
          "pod" => "nuclear-plant-5d8f-#{String.pad_leading("#{index}", 2, "0")}",
          "node" => "springfield-k8s",
          "created_by_kind" => "ReplicaSet",
          "created_by_name" => "nuclear-plant-5d8f"
        })
      end

    bare_pods =
      for index <- 1..@bare_pod_count do
        sample(%{
          "namespace" => "springfield-elementary",
          "pod" => "bart-prank-#{String.pad_leading("#{index}", 2, "0")}",
          "node" => "springfield-k8s"
        })
      end

    plant_pods ++
      bare_pods ++
      [
        sample(%{
          "namespace" => "entertainment",
          "pod" => "krusty-0",
          "node" => "springfield-k8s",
          "created_by_kind" => "StatefulSet",
          "created_by_name" => "krusty"
        })
      ]
  end

  @doc "`kube_pod_status_phase == 1` samples."
  def phases do
    [
      sample(%{"namespace" => "entertainment", "pod" => "krusty-0", "phase" => "Running"}),
      sample(%{
        "namespace" => "sector-7g",
        "pod" => "nuclear-plant-5d8f-01",
        "phase" => "Pending"
      })
    ]
  end

  @doc "`kube_replicaset_owner` samples."
  def replica_sets do
    [
      sample(%{
        "namespace" => "sector-7g",
        "replicaset" => "nuclear-plant-5d8f",
        "owner_kind" => "Deployment",
        "owner_name" => "nuclear-plant"
      })
    ]
  end

  @doc "`kube_pod_labels` samples (allowlisted `app.kubernetes.io/instance`)."
  def labels do
    [
      sample(%{
        "namespace" => "entertainment",
        "pod" => "krusty-0",
        "label_app_kubernetes_io_instance" => "krusty-show"
      })
    ]
  end

  @doc "`kube_node_info` samples."
  def nodes, do: [sample(%{"node" => "springfield-k8s", "internal_ip" => "10.0.0.11"})]

  @doc "`container_last_seen` samples of Docker containers."
  def containers do
    [
      sample(%{
        "instance" => "smithers.springfield.lan:8081",
        "name" => "duff-brewery",
        "image" => "duff/beer:latest",
        "container_label_com_docker_compose_project" => "duff"
      }),
      sample(%{
        "instance" => "smithers.springfield.lan:8081",
        "name" => "duff-brewery",
        "image" => "duff/beer:latest",
        "container_label_com_docker_compose_project" => "duff"
      }),
      sample(%{
        "instance" => "cadvisor:8080",
        "name" => "itchy-scratchy",
        "image" => "itchy/scratchy:1.0"
      })
    ]
  end

  defp sample(labels), do: %{"metric" => labels, "value" => [1_795_202_365.917, "1"]}
end
