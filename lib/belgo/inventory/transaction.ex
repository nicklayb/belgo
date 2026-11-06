defmodule Belgo.Inventory.Transaction do
  @moduledoc """
  Runs `Ecto.Multi` built by use cases against the inventory instead of a database.

  The multi is executed inside `Belgo.Inventory.Store`, so steps see the latest
  snapshot and no other change can interleave. Steps are `Ecto.Multi.run/3`
  functions receiving the current snapshot (in place of the repo) and the previous
  changes. A step returning `{:ok, %Belgo.Inventory.Transaction.Write{}}` changes the
  snapshot; files are only written once every step succeeded.

  Use `put/4` and `delete/4` rather than building write steps by hand.
  """

  alias Belgo.Inventory.Changes
  alias Belgo.Inventory.References
  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.Store

  defmodule Write do
    @moduledoc "A change of one record, produced by a transaction step."

    @enforce_keys [:operation, :collection, :record]
    defstruct [:operation, :collection, :record]

    @type t :: %__MODULE__{
            operation: :put | :delete,
            collection: Snapshot.collection(),
            record: Snapshot.entity()
          }
  end

  @type result :: {:ok, map()} | {:error, Ecto.Multi.name(), any(), map()}
  @type step_function :: (Snapshot.t(), map() -> {:ok, any()} | {:error, any()})

  @doc """
  Adds a step creating (`id` is `nil`) or updating a record from params. The step
  result is the saved record, its error the invalid changeset.
  """
  @spec put(Ecto.Multi.t(), Ecto.Multi.name(), Snapshot.collection(), {String.t() | nil, map()}) ::
          Ecto.Multi.t()
  def put(multi, name, collection, {id, params}) do
    Ecto.Multi.run(multi, name, fn snapshot, _changes ->
      with {:ok, record} <- fetch_optional(snapshot, collection, id),
           {:ok, saved} <- apply_params(snapshot, collection, record, params) do
        {:ok, %Write{operation: :put, collection: collection, record: saved}}
      end
    end)
  end

  @doc """
  Adds a step updating a record with params computed from its current version, read
  inside the transaction: `params_function` receives the record.
  """
  @spec update_with(
          Ecto.Multi.t(),
          Ecto.Multi.name(),
          Snapshot.collection(),
          String.t(),
          (Snapshot.entity() -> map())
        ) :: Ecto.Multi.t()
  def update_with(multi, name, collection, id, params_function) do
    Ecto.Multi.run(multi, name, fn snapshot, _changes ->
      with {:ok, record} <- Snapshot.fetch(snapshot, collection, id),
           {:ok, saved} <- apply_params(snapshot, collection, record, params_function.(record)) do
        {:ok, %Write{operation: :put, collection: collection, record: saved}}
      end
    end)
  end

  @doc """
  Adds a step creating the record identified by `id` only when it does not exist yet.
  The step result is the created or the existing record.
  """
  @spec put_missing(Ecto.Multi.t(), Ecto.Multi.name(), Snapshot.collection(), {String.t(), map()}) ::
          Ecto.Multi.t()
  def put_missing(multi, name, collection, {id, params}) do
    Ecto.Multi.run(multi, name, fn snapshot, _changes ->
      with {:error, :not_found} <- Snapshot.fetch(snapshot, collection, id),
           {:ok, saved} <- apply_params(snapshot, collection, nil, Map.put(params, "id", id)) do
        {:ok, %Write{operation: :put, collection: collection, record: saved}}
      end
    end)
  end

  @doc "Adds a step deleting the record identified by `id` when it exists; `nil` otherwise."
  @spec delete_existing(Ecto.Multi.t(), Ecto.Multi.name(), Snapshot.collection(), String.t()) ::
          Ecto.Multi.t()
  def delete_existing(multi, name, collection, id) do
    Ecto.Multi.run(multi, name, fn snapshot, _changes ->
      case Snapshot.fetch(snapshot, collection, id) do
        {:ok, record} -> {:ok, %Write{operation: :delete, collection: collection, record: record}}
        {:error, :not_found} -> {:ok, nil}
      end
    end)
  end

  defp apply_params(snapshot, collection, record, params) do
    snapshot
    |> Changes.build(collection, record, params)
    |> Ecto.Changeset.apply_action(if(record, do: :update, else: :insert))
  end

  @doc "Adds a step deleting a record, failing with `{:referenced, references}` when in use."
  @spec delete(Ecto.Multi.t(), Ecto.Multi.name(), Snapshot.collection(), String.t()) ::
          Ecto.Multi.t()
  def delete(multi, name, collection, id) do
    Ecto.Multi.run(multi, name, fn snapshot, _changes ->
      with {:ok, record} <- Snapshot.fetch(snapshot, collection, id),
           [] <- References.list(snapshot, collection, id) do
        {:ok, %Write{operation: :delete, collection: collection, record: record}}
      else
        [_reference | _rest] = references -> {:error, {:referenced, references}}
        error -> error
      end
    end)
  end

  @doc """
  Run function for `Box.UseCase`. Accepts a `:server` transaction option to target
  another store than the default one.
  """
  @spec run(Ecto.Multi.t(), Keyword.t()) :: result()
  def run(%Ecto.Multi{} = multi, options) do
    GenServer.call(Keyword.get(options, :server, Store), {:transaction, multi})
  end

  @doc """
  Applies the steps of a multi to a snapshot. Returns the new snapshot, the changed
  collections and the changes, or the failing step like `Ecto.Repo.transaction/2`.
  """
  @spec apply(Snapshot.t(), Ecto.Multi.t()) ::
          {:ok, Snapshot.t(), [Snapshot.collection()], map()}
          | {:error, Ecto.Multi.name(), any(), map()}
  def apply(%Snapshot{} = snapshot, %Ecto.Multi{} = multi) do
    multi
    |> Ecto.Multi.to_list()
    |> Enum.reduce_while({:ok, snapshot, [], %{}}, &apply_step/2)
  end

  defp apply_step({name, {:run, function}}, {:ok, snapshot, collections, changes}) do
    case function.(snapshot, changes) do
      {:ok, %Write{} = write} ->
        {:cont,
         {:ok, write_snapshot(snapshot, write), Enum.uniq([write.collection | collections]),
          Map.put(changes, name, write.record)}}

      {:ok, value} ->
        {:cont, {:ok, snapshot, collections, Map.put(changes, name, value)}}

      {:error, value} ->
        {:halt, {:error, name, value, changes}}
    end
  end

  defp apply_step({name, operation}, _accumulator) do
    raise ArgumentError,
          "inventory transactions only support Ecto.Multi.run/3 steps, got #{inspect(elem(operation, 0))} for #{inspect(name)}"
  end

  defp write_snapshot(snapshot, %Write{operation: :put} = write),
    do: Snapshot.put(snapshot, write.collection, write.record)

  defp write_snapshot(snapshot, %Write{operation: :delete} = write),
    do: Snapshot.delete(snapshot, write.collection, write.record.id)

  defp fetch_optional(_snapshot, _collection, nil), do: {:ok, nil}
  defp fetch_optional(snapshot, collection, id), do: Snapshot.fetch(snapshot, collection, id)
end
