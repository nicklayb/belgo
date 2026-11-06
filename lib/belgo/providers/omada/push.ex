defmodule Belgo.Providers.Omada.Push do
  @moduledoc """
  Plans the Omada client renames needed for a desired state. Pure functions only.

  Each MAC address of a device should carry the device name. Omada only lists clients
  it has seen, so missing ones are reported as skipped; nothing is created or deleted.
  """

  alias Belgo.Network.MacAddress
  alias Belgo.Sync.DesiredState

  defmodule Operation do
    @moduledoc "One client rename on the controller."
    @enforce_keys [:client_mac, :name, :summary]
    defstruct [:client_mac, :name, :summary]

    @type t :: %__MODULE__{client_mac: String.t(), name: String.t(), summary: String.t()}
  end

  @type plan :: %{operations: [Operation.t()], skipped: [String.t()]}

  @doc "Plans the renames from the connected clients listed by the controller."
  @spec plan(DesiredState.t(), [map()]) :: plan()
  def plan(%DesiredState{client_names: desired}, clients) do
    client_by_mac =
      for %{"mac" => raw_mac} = client <- clients,
          {:ok, mac} <- [MacAddress.normalize(raw_mac)],
          into: %{},
          do: {mac, client}

    Enum.reduce(desired, %{operations: [], skipped: []}, fn client_name, plan ->
      case Map.fetch(client_by_mac, client_name.mac) do
        {:ok, %{"name" => name}} when name == client_name.name ->
          plan

        {:ok, %{"mac" => raw_mac} = client} ->
          operation = %Operation{
            client_mac: raw_mac,
            name: client_name.name,
            summary:
              "rename client #{client_name.mac}: #{client["name"] || "unnamed"} → #{client_name.name}"
          }

          %{plan | operations: plan.operations ++ [operation]}

        :error ->
          %{
            plan
            | skipped:
                plan.skipped ++ ["#{client_name.mac}: not connected to Omada, name not pushed"]
          }
      end
    end)
  end
end
