defmodule Belgo.Inventory.UseCase.UpdateDevices do
  @moduledoc """
  Applies a `Belgo.Inventory.BulkEdit` to several devices in one transaction: every
  device is saved or none is. Params are `{device_ids, bulk_edit_params}`; each step is
  named `{:device, id}` so a failure tells which device is invalid. Saved devices are
  pushed like any saved device. Returns the updated devices.
  """

  use Belgo.UseCase

  alias Belgo.Inventory.BulkEdit
  alias Belgo.Inventory.Transaction

  @impl Box.UseCase
  def validate({[_first | _others] = device_ids, params}, options) when is_map(params) do
    with {:ok, _user} <- authorize(options),
         {:ok, bulk_edit} <-
           params
           |> BulkEdit.changeset()
           |> Ecto.Changeset.apply_action(:update) do
      {:ok, {Enum.uniq(device_ids), bulk_edit}}
    end
  end

  def validate({[], _params}, _options), do: {:error, :no_device}

  @impl Box.UseCase
  def run(multi, {device_ids, bulk_edit}, _options) do
    Enum.reduce(device_ids, multi, fn device_id, accumulator ->
      Transaction.update_with(
        accumulator,
        {:device, device_id},
        :devices,
        device_id,
        &BulkEdit.device_params(bulk_edit, &1)
      )
    end)
  end

  @impl Box.UseCase
  def after_run(changes, _options) do
    for device <- devices(changes), do: Belgo.Sync.after_save(:devices, device)
    :ok
  end

  @impl Box.UseCase
  def return(changes, _options), do: devices(changes)

  defp devices(changes) do
    for {{:device, _id}, device} <- changes, do: device
  end
end
