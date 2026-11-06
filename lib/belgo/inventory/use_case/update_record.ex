defmodule Belgo.Inventory.UseCase.UpdateRecord do
  @moduledoc """
  Updates a location, network or device. Params are `{collection, id, attributes}`;
  the identifier itself cannot change since other records reference it.
  """

  use Belgo.UseCase

  alias Belgo.Inventory.Transaction

  @impl Box.UseCase
  def validate({_collection, _id, _attributes} = params, options) do
    with {:ok, _user} <- authorize(options), do: {:ok, params}
  end

  @impl Box.UseCase
  def run(multi, {collection, id, attributes}, _options) do
    Transaction.put(multi, :record, collection, {id, attributes})
  end

  @impl Box.UseCase
  def after_run(%{record: record}, options) do
    options
    |> Keyword.fetch!(:params)
    |> elem(0)
    |> Belgo.Sync.after_save(record)
  end

  @impl Box.UseCase
  def return(%{record: record}, _options), do: record
end
