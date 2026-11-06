defmodule Belgo.Inventory.Storage do
  @moduledoc """
  Behaviour of the persistence of the inventory. Storages are the only place where
  the inventory touches the outside world.
  """

  alias Belgo.Inventory.Snapshot

  @type options :: Keyword.t()
  @type t :: {module(), options()}

  @doc "Loads the whole inventory. Errors are human readable messages."
  @callback load(options()) :: {:ok, Snapshot.t()} | {:error, [String.t()]}

  @doc "Persists one collection of the snapshot."
  @callback save(options(), Snapshot.t(), Snapshot.collection()) :: :ok | {:error, any()}

  @doc "Loads the inventory with the given storage."
  @spec load(t()) :: {:ok, Snapshot.t()} | {:error, [String.t()]}
  def load({module, options}), do: module.load(options)

  @doc "Persists a collection with the given storage."
  @spec save(t(), Snapshot.t(), Snapshot.collection()) :: :ok | {:error, any()}
  def save({module, options}, snapshot, collection),
    do: module.save(options, snapshot, collection)
end
