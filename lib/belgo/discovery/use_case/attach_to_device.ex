defmodule Belgo.Discovery.UseCase.AttachToDevice do
  @moduledoc """
  Claims a discovered device as new interfaces of an existing device (a second NIC,
  a Wi-Fi card…). Params are `{discovered_device, device_id}`; interfaces whose MAC or
  IP address the device already has are not added again. Returns the updated device,
  which is then pushed like any saved device.
  """

  use Belgo.UseCase

  alias Belgo.Discovery.Correlation.DiscoveredDevice
  alias Belgo.Discovery.Suggestion
  alias Belgo.Inventory
  alias Belgo.Inventory.Codec
  alias Belgo.Inventory.Transaction

  @impl Box.UseCase
  def validate({%DiscoveredDevice{}, device_id} = params, options) when is_binary(device_id) do
    with {:ok, _user} <- authorize(options), do: {:ok, params}
  end

  @impl Box.UseCase
  def run(multi, {discovered, device_id}, options) do
    snapshot =
      options
      |> Keyword.get(:transaction, [])
      |> Keyword.get(:server, Inventory.Store)
      |> Inventory.snapshot()

    new_interfaces = Suggestion.interface_params(discovered, snapshot)

    Transaction.update_with(multi, :record, :devices, device_id, fn device ->
      attributes = Codec.encode(device)
      existing = Map.get(attributes, "interfaces", [])

      Map.put(
        attributes,
        "interfaces",
        existing ++ Enum.reject(new_interfaces, &known?(&1, device))
      )
    end)
  end

  @impl Box.UseCase
  def after_run(%{record: record}, _options), do: Belgo.Sync.after_save(:devices, record)

  @impl Box.UseCase
  def return(%{record: record}, _options), do: record

  defp known?(interface, device) do
    Enum.any?(device.interfaces, fn existing ->
      (interface["mac"] && interface["mac"] == existing.mac) or
        (interface["ip"] && interface["ip"] == existing.ip)
    end)
  end
end
