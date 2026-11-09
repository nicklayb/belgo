defmodule Belgo.Inventory.UseCase.DeleteRecord do
  @moduledoc """
  Deletes a location, network or device. Params are `{collection, id}`. Fails with
  `{:referenced, references}` while other records point at it.
  """

  use Belgo.UseCase

  alias Belgo.Inventory.Transaction

  @impl Box.UseCase
  def validate({_collection, _id} = params, options) do
    with {:ok, _user} <- authorize(options), do: {:ok, params}
  end

  @impl Box.UseCase
  def run(multi, {collection, id}, _options) do
    Transaction.delete(multi, :record, collection, id)
  end

  @impl Box.UseCase
  def after_run(%{record: record}, options) do
    options
    |> Keyword.fetch!(:params)
    |> elem(0)
    |> Belgo.Sync.after_delete(record)
  end

  @impl Box.UseCase
  def return(%{record: record}, _options), do: record
end
