defmodule Belgo.Inventory.Store do
  @moduledoc """
  Process owning the in-memory snapshot of the inventory.

  The snapshot is loaded from the storage at boot (failing loudly on invalid files)
  and mutations, made by use cases through `Belgo.Inventory.Transaction`, are persisted
  before being broadcast on `topic/0`. Transactions are serialised through this
  process so that validation always runs against the latest snapshot.

  Options:

    * `:storage` – `{module, options}` implementing `Belgo.Inventory.Storage` (required)
    * `:name` – process name, defaults to the module name
    * `:pubsub` – `Phoenix.PubSub` server to broadcast to, `nil` to disable
  """

  use GenServer

  alias Belgo.Inventory.Storage
  alias Belgo.Inventory.Transaction

  require Logger

  @topic "inventory"

  @doc "Starts the store."
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc "PubSub topic receiving `{:inventory_changed, snapshot}` messages."
  @spec topic() :: String.t()
  def topic, do: @topic

  @impl GenServer
  def init(options) do
    storage = Keyword.fetch!(options, :storage)

    case Storage.load(storage) do
      {:ok, snapshot} ->
        {:ok, %{storage: storage, snapshot: snapshot, pubsub: Keyword.get(options, :pubsub)}}

      {:error, messages} ->
        Logger.error("Unable to load the inventory:\n  " <> Enum.join(messages, "\n  "))
        {:stop, {:invalid_inventory, messages}}
    end
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  def handle_call({:transaction, multi}, _from, state) do
    with {:ok, snapshot, collections, changes} <- Transaction.apply(state.snapshot, multi),
         :ok <- persist(state.storage, snapshot, collections) do
      {:reply, {:ok, changes}, publish(state, snapshot)}
    else
      {:error, {:persist, reason}} -> {:reply, {:error, :persist, reason, %{}}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:reload, _from, state) do
    case Storage.load(state.storage) do
      {:ok, snapshot} -> {:reply, :ok, publish(state, snapshot)}
      {:error, messages} -> {:reply, {:error, {:invalid_inventory, messages}}, state}
    end
  end

  defp persist(storage, snapshot, collections) do
    Enum.reduce_while(collections, :ok, fn collection, :ok ->
      case Storage.save(storage, snapshot, collection) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:persist, reason}}}
      end
    end)
  end

  defp publish(state, snapshot) do
    if state.pubsub do
      Phoenix.PubSub.broadcast(state.pubsub, @topic, {:inventory_changed, snapshot})
    end

    %{state | snapshot: snapshot}
  end
end
