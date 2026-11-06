defmodule Belgo.Inventory.UseCase.CreateRecord do
  @moduledoc """
  Creates a location, network or device. Params are `{collection, attributes}`;
  returns the created record or the invalid changeset.
  """

  use Belgo.UseCase

  alias Belgo.Inventory.Transaction

  @impl Box.UseCase
  def validate({_collection, _attributes} = params, options) do
    with {:ok, _user} <- authorize(options), do: {:ok, params}
  end

  @impl Box.UseCase
  def run(multi, {collection, attributes}, _options) do
    Transaction.put(multi, :record, collection, {nil, attributes})
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
