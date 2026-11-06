defmodule BelgoWeb.Hooks.Notifications do
  @moduledoc """
  Shows background outcomes as flash messages on whatever page is open, e.g. a
  device woken up with wake-on-LAN answering (or not) its pings.
  """

  use Gettext, backend: BelgoWeb.Gettext

  alias Belgo.WakeOnLan
  alias Belgo.WakeOnLan.Outcome

  @milliseconds_per_second 1_000

  @doc false
  def on_mount(:default, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket), do: WakeOnLan.subscribe()
    {:cont, Phoenix.LiveView.attach_hook(socket, :notifications, :handle_info, &handle_info/2)}
  end

  @doc "The flash kind and message of a wake-on-LAN outcome."
  @spec wake_on_lan_message(Outcome.t()) :: {:info | :error, String.t()}
  def wake_on_lan_message(%Outcome{result: :awake} = outcome),
    do:
      {:info,
       gettext("%{name} is awake (answered after %{seconds} s).",
         name: outcome.device_name,
         seconds: div(outcome.elapsed, @milliseconds_per_second)
       )}

  def wake_on_lan_message(%Outcome{result: :timeout} = outcome),
    do:
      {:error,
       gettext("%{name} did not answer within %{seconds} s after wake-on-LAN.",
         name: outcome.device_name,
         seconds: div(outcome.timeout, @milliseconds_per_second)
       )}

  defp handle_info({:wake_on_lan, %Outcome{} = outcome}, socket) do
    {kind, message} = wake_on_lan_message(outcome)
    {:halt, Phoenix.LiveView.put_flash(socket, kind, message)}
  end

  defp handle_info(_message, socket), do: {:cont, socket}
end
