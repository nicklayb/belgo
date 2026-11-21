defmodule Belgo.Topology.WorkloadTreeTest do
  use ExUnit.Case, async: true

  alias Belgo.Discovery.Workload
  alias Belgo.Discovery.Workload.HostReference
  alias Belgo.Topology.WorkloadTree
  alias Belgo.Topology.WorkloadTree.Group

  defp workload(attributes) do
    struct!(
      %Workload{
        provider: :prometheus,
        source: :kube_pod,
        kind: :pod,
        name: "unnamed",
        host: %HostReference{name: "springfield-k8s"}
      },
      attributes
    )
  end

  test "pods are nested under their application, groups first, then bare pods" do
    first_speaker =
      workload(name: "metallb-speaker-x2", namespace: "metallb", group: "metallb-speaker")

    second_speaker =
      workload(name: "metallb-speaker-64p8t", namespace: "metallb", group: "metallb-speaker")

    krusty = workload(name: "krusty-0", namespace: "entertainment", group: "Krusty-show")
    bare = workload(name: "bart-prank", namespace: "springfield-elementary", group: "bart-prank")
    other_bare = workload(name: "apu-shift", namespace: "kwik-e-mart", group: nil)

    assert [
             %Group{name: "Krusty-show", namespace: "entertainment", workloads: [^krusty]},
             %Group{
               name: "metallb-speaker",
               namespace: "metallb",
               workloads: [^second_speaker, ^first_speaker]
             },
             ^other_bare,
             ^bare
           ] = WorkloadTree.build([first_speaker, bare, krusty, other_bare, second_speaker])
  end

  test "groups of the same name in different namespaces stay apart" do
    production = workload(name: "duff-1", namespace: "production", group: "duff")
    staging = workload(name: "duff-2", namespace: "staging", group: "duff")

    assert [
             %Group{namespace: "production", workloads: [^production]},
             %Group{namespace: "staging", workloads: [^staging]}
           ] = WorkloadTree.build([staging, production])
  end

  test "containers are nested under their Compose project" do
    sonarr = workload(kind: :container, name: "sonarr", group: "torrent")
    radarr = workload(kind: :container, name: "radarr", group: "torrent")
    loose = workload(kind: :container, name: "itchy-scratchy", group: nil)

    entries = WorkloadTree.build([sonarr, loose, radarr])

    assert [%Group{name: "torrent", namespace: nil, workloads: [^radarr, ^sonarr]}, ^loose] =
             entries

    assert WorkloadTree.workload_count(entries) == 3
  end

  test "a workload is grouped unless its group is missing or its own name" do
    assert WorkloadTree.grouped?(workload(name: "sonarr", group: "torrent"))
    refute WorkloadTree.grouped?(workload(name: "sonarr", group: nil))
    refute WorkloadTree.grouped?(workload(name: "sonarr", group: ""))
    refute WorkloadTree.grouped?(workload(name: "sonarr", group: "sonarr"))
  end
end
