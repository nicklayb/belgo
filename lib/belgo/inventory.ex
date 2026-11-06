defmodule Belgo.Inventory do
  @moduledoc """
  Entry point of the inventory: the single source of truth of the homelab.

  Reads return an immutable `Belgo.Inventory.Snapshot`; derived views (topology,
  synchronisation, issues) are pure functions of it. Mutations are use cases
  (`Belgo.Inventory.UseCase.*`).
  """

  alias Belgo.Inventory.Audit
  alias Belgo.Inventory.Changes
  alias Belgo.Inventory.Device
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.Store
  alias Belgo.Inventory.UseCase

  @type server :: GenServer.server()

  @doc "Returns the current snapshot."
  @spec snapshot(server()) :: Snapshot.t()
  def snapshot(server \\ Store), do: GenServer.call(server, :snapshot)

  @doc "Subscribes the calling process to `{:inventory_changed, snapshot}` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Belgo.PubSub, Store.topic())

  @doc "Builds a changeset for forms, validated against the snapshot. `nil` means a new record."
  @spec change(Snapshot.t(), Snapshot.collection(), Snapshot.entity() | nil, map()) ::
          Ecto.Changeset.t()
  defdelegate change(snapshot, collection, record, params), to: Changes, as: :build

  @doc "Creates a record on behalf of `options[:user]`."
  @spec create(Snapshot.collection(), map(), Keyword.t()) ::
          {:ok, Snapshot.entity()} | {:error, atom(), any(), map()} | {:error, any()}
  def create(collection, attributes, options) do
    Belgo.UseCase.execute(UseCase.CreateRecord, {collection, attributes}, options)
  end

  @doc "Updates a record on behalf of `options[:user]`."
  @spec update(Snapshot.collection(), String.t(), map(), Keyword.t()) ::
          {:ok, Snapshot.entity()} | {:error, atom(), any(), map()} | {:error, any()}
  def update(collection, id, attributes, options) do
    Belgo.UseCase.execute(UseCase.UpdateRecord, {collection, id, attributes}, options)
  end

  @doc """
  Applies a bulk edit (`Belgo.Inventory.BulkEdit` params) to several devices on behalf
  of `options[:user]`, all or nothing.
  """
  @spec update_devices([String.t()], map(), Keyword.t()) ::
          {:ok, [Device.t()]} | {:error, atom() | tuple(), any(), map()} | {:error, any()}
  def update_devices(device_ids, params, options) do
    Belgo.UseCase.execute(UseCase.UpdateDevices, {device_ids, params}, options)
  end

  @doc """
  Deletes a record on behalf of `options[:user]`. Fails with
  `{:error, :record, {:referenced, references}, _}` while the record is referenced.
  """
  @spec delete(Snapshot.collection(), String.t(), Keyword.t()) ::
          {:ok, Snapshot.entity()} | {:error, atom(), any(), map()} | {:error, any()}
  def delete(collection, id, options) do
    Belgo.UseCase.execute(UseCase.DeleteRecord, {collection, id}, options)
  end

  @doc "Reloads the inventory from the storage, keeping the current one if files are invalid."
  @spec reload(server()) :: :ok | {:error, {:invalid_inventory, [String.t()]}}
  def reload(server \\ Store), do: GenServer.call(server, :reload)

  @doc "Lists every consistency issue of the snapshot."
  @spec issues(Snapshot.t()) :: [Belgo.Inventory.Issue.t()]
  defdelegate issues(snapshot), to: Audit
end
