defmodule BelgoWeb.Live.RecordForm do
  @moduledoc """
  Shared behaviour of the simple create / edit pages (locations, networks): loading
  the record, validating against the inventory and saving through the use cases.
  """

  use Gettext, backend: BelgoWeb.Gettext

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3, push_navigate: 2]

  alias Belgo.Inventory
  alias Belgo.Inventory.Snapshot
  alias BelgoWeb.Live.Mutation

  @doc """
  Assigns `record` (`nil` for new ones) and `form`. Redirects to `index_path` when
  the record does not exist.
  """
  @spec mount(Phoenix.LiveView.Socket.t(), Snapshot.collection(), map(), map(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def mount(socket, collection, params, defaults, index_path) do
    with %{"id" => id} <- params,
         {:error, :not_found} <- Snapshot.fetch(socket.assigns.snapshot, collection, id) do
      socket
      |> put_flash(:error, gettext("This record no longer exists."))
      |> push_navigate(to: index_path)
    else
      {:ok, record} ->
        socket
        |> assign(:record, record)
        |> assign_form(collection, %{})

      _new ->
        socket
        |> assign(:record, nil)
        |> assign_form(collection, defaults)
    end
  end

  @doc "Re-validates the form with the submitted params."
  @spec validate(Phoenix.LiveView.Socket.t(), Snapshot.collection(), map()) ::
          Phoenix.LiveView.Socket.t()
  def validate(socket, collection, params), do: assign_form(socket, collection, params, :validate)

  @doc "Saves the record and navigates to `index_path`, or shows the errors."
  @spec save(Phoenix.LiveView.Socket.t(), Snapshot.collection(), map(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def save(socket, collection, params, index_path) do
    result =
      case socket.assigns.record do
        nil -> Inventory.create(collection, params, Mutation.options(socket))
        record -> Inventory.update(collection, record.id, params, Mutation.options(socket))
      end

    case result do
      {:ok, record} ->
        socket
        |> put_flash(:info, gettext("%{name} saved.", name: record.name))
        |> push_navigate(to: index_path)

      {:error, :record, %Ecto.Changeset{} = changeset, _changes} ->
        assign(socket, :form, to_form(changeset, action: :validate))

      error ->
        put_flash(socket, :error, Mutation.describe_error(error))
    end
  end

  defp assign_form(socket, collection, params, action \\ nil) do
    changeset =
      Inventory.change(socket.assigns.snapshot, collection, socket.assigns.record, params)

    assign(socket, :form, to_form(changeset, action: action))
  end
end
