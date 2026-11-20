defmodule BelgoWeb.Live.SetHost do
  @moduledoc """
  The "Set host" action shared by the device and Hosting pages: moves a guest device
  onto the host a provider sees it running on (`Belgo.Discovery.Workloads`), on the
  user's click only. Saved like any device edit (then pushed).
  """

  use Gettext, backend: BelgoWeb.Gettext

  alias Belgo.Discovery.Workloads
  alias Belgo.Inventory
  alias Belgo.Inventory.Snapshot
  alias BelgoWeb.Live.Mutation

  @doc "Handles the `set-host` event (`device_id` param) and puts a flash with the outcome."
  @spec handle(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def handle(socket, device_id) do
    workloads = socket.assigns.discovery.correlation.workloads

    with %{host_id: host_id} = placement when is_binary(host_id) <-
           Workloads.placement(workloads, device_id),
         {:ok, device} <- Snapshot.fetch(socket.assigns.snapshot, :devices, device_id) do
      params = Workloads.host_params(device, placement)

      case Inventory.update(:devices, device_id, params, Mutation.options(socket)) do
        {:ok, device} ->
          Phoenix.LiveView.put_flash(
            socket,
            :info,
            gettext("%{name} now runs on %{host}.", name: device.name, host: placement.host_name)
          )

        error ->
          Phoenix.LiveView.put_flash(socket, :error, Mutation.describe_error(error))
      end
    else
      _unknown ->
        Phoenix.LiveView.put_flash(
          socket,
          :error,
          gettext("No provider reports a known host for this device.")
        )
    end
  end
end
