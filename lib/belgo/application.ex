defmodule Belgo.Application do
  @moduledoc false

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Belgo.PubSub},
      {Task.Supervisor, name: Belgo.TaskSupervisor},
      {Belgo.Inventory.Store, storage: inventory_storage(), pubsub: Belgo.PubSub},
      {Belgo.Discovery.Server, discovery_options()},
      {Belgo.Reachability.Server, reachability_options()},
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
  end

  defp reachability_options do
    :belgo
    |> Application.get_env(Belgo.Reachability, [])
    |> Keyword.put(:pubsub, Belgo.PubSub)
  end

  defp inventory_storage do
    :belgo
    |> Application.fetch_env!(Belgo.Inventory)
    |> Keyword.fetch!(:storage)
  end
end
