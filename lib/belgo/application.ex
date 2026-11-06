defmodule Belgo.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Belgo.PubSub},
      {Task.Supervisor, name: Belgo.TaskSupervisor},
      {Belgo.Inventory.Store, storage: inventory_storage(), pubsub: Belgo.PubSub},
      {Belgo.Reachability.Server, reachability_options()},
      {Belgo.PortScan.Server, port_scan_options()},
      {Registry, keys: :unique, name: Belgo.WakeOnLan.Registry},
      {DynamicSupervisor, name: Belgo.WakeOnLan.Supervisor, strategy: :one_for_one},
      {Belgo.Discovery.Server, discovery_options()},
      {Belgo.Versioning.Server, versioning_options()},
      BelgoWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Belgo.Supervisor)
  end

  @impl Application
  def config_change(changed, _new, removed) do
    BelgoWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp discovery_options do
    :belgo
    |> Application.fetch_env!(Belgo.Discovery)
    |> Keyword.put(:pubsub, Belgo.PubSub)
    |> Keyword.put_new(:reachability, Belgo.Reachability.Server)
  end

  defp reachability_options do
    :belgo
    |> Application.get_env(Belgo.Reachability, [])
    |> Keyword.put(:pubsub, Belgo.PubSub)
  end

  defp port_scan_options do
    :belgo
    |> Application.fetch_env!(Belgo.PortScan)
    |> Keyword.put(:pubsub, Belgo.PubSub)
  end

  defp versioning_options do
    :belgo
    |> Application.fetch_env!(Belgo.Versioning)
    |> Keyword.put(:pubsub, Belgo.PubSub)
  end

  defp inventory_storage do
    :belgo
    |> Application.fetch_env!(Belgo.Inventory)
    |> Keyword.fetch!(:storage)
  end
end
