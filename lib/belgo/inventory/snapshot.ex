defmodule Belgo.Inventory.Snapshot do
  @moduledoc """
  The complete inventory at a given time. It is exactly what the data files contain:
  everything else in Belgo is computed from it.

  Records of every collection are kept sorted by identifier so that the same files
  always produce the same snapshot.
  """

  alias Belgo.Inventory.DeniedDevice
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Location
  alias Belgo.Inventory.Network
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.VirtualIp

  defstruct locations: [], networks: [], devices: [], virtual_ips: [], denylist: []

  @type collection :: :locations | :networks | :devices | :virtual_ips | :denylist
  @type entity :: Location.t() | Network.t() | Device.t() | VirtualIp.t() | DeniedDevice.t()
  @type t :: %Snapshot{
          locations: [Location.t()],
          networks: [Network.t()],
          devices: [Device.t()],
          virtual_ips: [VirtualIp.t()],
          denylist: [DeniedDevice.t()]
        }

  @schema_by_collection %{
    locations: Location,
    networks: Network,
    devices: Device,
    virtual_ips: VirtualIp,
    denylist: DeniedDevice
  }
  @collections [:locations, :networks, :devices, :virtual_ips, :denylist]

  @doc "Lists the collections in loading order."
  @spec collections() :: [collection()]
  def collections, do: @collections

  @doc "Returns the schema module of a collection."
  @spec schema(collection()) :: module()
  def schema(collection), do: Map.fetch!(@schema_by_collection, collection)

  @doc "Builds a snapshot from records grouped by collection, sorting them."
  @spec new(%{optional(collection()) => [entity()]}) :: t()
  def new(records_by_collection) do
    Enum.reduce(records_by_collection, %Snapshot{}, fn {collection, records}, snapshot ->
      Map.put(snapshot, collection, Enum.sort_by(records, & &1.id))
    end)
  end

  @doc "Lists the records of a collection."
  @spec list(t(), collection()) :: [entity()]
  def list(%Snapshot{} = snapshot, collection), do: Map.fetch!(snapshot, collection)

  @doc "Returns the records of a collection keyed by identifier."
  @spec index(t(), collection()) :: %{String.t() => entity()}
  def index(%Snapshot{} = snapshot, collection) do
    snapshot
    |> list(collection)
    |> Map.new(&{&1.id, &1})
  end

  @doc "Fetches a record by identifier."
  @spec fetch(t(), collection(), String.t()) :: {:ok, entity()} | {:error, :not_found}
  def fetch(%Snapshot{} = snapshot, collection, id) do
    case Enum.find(list(snapshot, collection), &(&1.id == id)) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc "Inserts or replaces a record, keeping the collection sorted."
  @spec put(t(), collection(), entity()) :: t()
  def put(%Snapshot{} = snapshot, collection, record) do
    records =
      snapshot
      |> list(collection)
      |> Enum.reject(&(&1.id == record.id))
      |> List.insert_at(0, record)
      |> Enum.sort_by(& &1.id)

    Map.put(snapshot, collection, records)
  end

  @doc "Removes a record by identifier."
  @spec delete(t(), collection(), String.t()) :: t()
  def delete(%Snapshot{} = snapshot, collection, id) do
    Map.update!(snapshot, collection, fn records -> Enum.reject(records, &(&1.id == id)) end)
  end
end
