defmodule Belgo.Providers.PrometheusTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Report
  alias Belgo.Discovery.Workload
  alias Belgo.Discovery.Workload.HostReference
  alias Belgo.Fixtures.PrometheusClient
  alias Belgo.Providers.Prometheus
  alias Belgo.Providers.Prometheus.HttpClient
  alias Belgo.Providers.Prometheus.Translate

  defp config(attributes \\ []) do
    struct!(
      %Prometheus.Config{url: "https://prometheus.springfield.lan", client: PrometheusClient},
      attributes
    )
  end

  describe "parse_config/2" do
    test "accepts Grafana, namespaces, instances and an optional token" do
      options = %{
        "url" => "https://grafana.springfield.lan/",
        "datasource_uid" => "springfield-prometheus",
        "namespaces" => ["sector-7g", "entertainment"],
        "instances" => %{"cadvisor:8080" => "smithers"}
      }

      assert {:ok,
              %Prometheus.Config{
                url: "https://grafana.springfield.lan",
                datasource_uid: "springfield-prometheus",
                namespaces: ["sector-7g", "entertainment"],
                instances: %{"cadvisor:8080" => "smithers"},
                token: "glsa_lard_lad",
                verify_tls: true
              }} =
               Prometheus.parse_config(options, %{"BELGO_PROMETHEUS_TOKEN" => "glsa_lard_lad"})

      assert {:ok, %Prometheus.Config{token: nil, namespaces: nil, instances: %{}}} =
               Prometheus.parse_config(%{"url" => "http://monitor:9090"}, %{})
    end

    test "rejects invalid options" do
      assert {:error, messages} =
               Prometheus.parse_config(
                 %{
                   "url" => "monitor",
                   "namespaces" => ["Sector 7G"],
                   "instances" => ["cadvisor"],
                   "mode" => "x"
                 },
                 %{}
               )

      assert "url must be an http(s) URL" in messages
      assert "namespaces must be a list of Kubernetes namespace names" in messages
      assert "instances must map scrape targets to device identifiers" in messages
      assert Enum.any?(messages, &(&1 =~ "unknown options: mode"))
    end

    test "is read only" do
      refute function_exported?(Prometheus, :push, 2)
    end
  end

  test "queries Grafana's data source proxy when a data source is set" do
    assert HttpClient.query_path(config()) == "/api/v1/query"

    assert HttpClient.query_path(config(datasource_uid: "afw2akionwj5se")) ==
             "/api/datasources/proxy/uid/afw2akionwj5se/api/v1/query"
  end

  describe "Translate" do
    test "pod queries follow the namespaces" do
      assert %{pods: "kube_pod_info", nodes: "kube_node_info"} = Translate.pod_queries(nil)

      assert %{
               pods: ~s|kube_pod_info{namespace=~"sector-7g\|entertainment"}|,
               phases: ~s|kube_pod_status_phase{namespace=~"sector-7g\|entertainment"} == 1|
             } = Translate.pod_queries(["sector-7g", "entertainment"])
    end

    test "pods are grouped by instance label, else by owning workload, on their node" do
      pods =
        Translate.pods(%{
          pods: PrometheusClient.pods(),
          phases: PrometheusClient.phases(),
          replica_sets: PrometheusClient.replica_sets(),
          labels: PrometheusClient.labels(),
          nodes: PrometheusClient.nodes()
        })

      assert length(pods) == 22

      assert %Workload{
               kind: :pod,
               source: :kube_pod,
               group: "krusty-show",
               namespace: "entertainment",
               status: "Running",
               host: %HostReference{name: "springfield-k8s", ips: ["10.0.0.11"]}
             } = Enum.find(pods, &(&1.name == "krusty-0"))

      assert %Workload{group: "nuclear-plant", status: "Pending"} =
               Enum.find(pods, &(&1.name == "nuclear-plant-5d8f-01"))

      assert %Workload{group: "nuclear-plant", status: nil} =
               Enum.find(pods, &(&1.name == "nuclear-plant-5d8f-02"))
    end

    test "pods without labels nor replica set owner fall back to their creator" do
      [pod] =
        Translate.pods(%{
          pods: [hd(PrometheusClient.pods())],
          phases: [],
          replica_sets: [],
          labels: [],
          nodes: []
        })

      assert %Workload{group: "nuclear-plant-5d8f", host: %HostReference{ips: []}} = pod
    end

    test "containers are deduplicated, hosted by their scrape target" do
      assert [
               %Workload{
                 kind: :container,
                 name: "duff-brewery",
                 image: "duff/beer:latest",
                 group: "duff",
                 status: "running",
                 host: %HostReference{name: "smithers.springfield.lan", device_id: nil}
               },
               %Workload{
                 name: "itchy-scratchy",
                 group: nil,
                 host: %HostReference{name: "cadvisor", device_id: "smithers"}
               }
             ] =
               Translate.containers(PrometheusClient.containers(), %{
                 "cadvisor:8080" => "smithers"
               })
    end

    test "instance hosts drop the port, IP targets are addresses" do
      assert Translate.instance_host("skynet.home.lan:8081") == "skynet.home.lan"
      assert Translate.instance_host("cadvisor") == "cadvisor"

      assert [%Workload{host: %HostReference{name: "10.0.0.11", ips: ["10.0.0.11"]}}] =
               Translate.containers(
                 [
                   %{
                     "metric" => %{
                       "instance" => "10.0.0.11:8080",
                       "name" => "lard",
                       "image" => "lad"
                     }
                   }
                 ],
                 %{}
               )
    end
  end

  describe "discover/1" do
    test "reports pods and containers" do
      assert {:ok,
              %Report{provider: :prometheus, workloads: workloads, failures: [], counts: counts}} =
               Prometheus.discover(config())

      assert length(workloads) == 24
      assert counts == %{kube_pod: 22, docker_container: 2}
    end

    test "a failing part is reported, the other kept" do
      assert {:ok, %Report{workloads: workloads, failures: [pods: {_query, _reason}]}} =
               Prometheus.discover(config(url: "https://pods-broken.example"))

      assert Enum.all?(workloads, &(&1.kind == :container))
    end

    test "fails when nothing can be read" do
      assert {:error, [pods: _pods, containers: _containers]} =
               Prometheus.discover(config(url: "https://broken.example"))
    end
  end
end
