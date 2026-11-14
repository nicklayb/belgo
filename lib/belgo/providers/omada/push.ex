defmodule Belgo.Providers.Omada.Push do
  @moduledoc """
  Plans the Omada client changes needed for a desired state. Pure functions only.

  Each MAC address of a device should carry the device name (`:rename`, Open API)
  and the device's type, vendor and model (`:correct`, the controller's web API, the
  Open API has no endpoint for them). The type is the Omada type of the device kind
  among the controller's `types` (`Omada.DeviceTypes`; a current type of the same
  kind is kept), the vendor and model its
  `Brand` / `Model` metadata; a value Belgo does not have keeps the client's current
  one. Corrections need web credentials (`web_access?`), else they are skipped and
  reported. Omada only lists clients it has seen, so missing ones are reported as
  skipped; nothing is created or deleted.
  """

  alias Belgo.Network.MacAddress
  alias Belgo.Providers.Omada.DeviceTypes
  alias Belgo.Sync.DesiredState
  alias Belgo.Sync.DesiredState.ClientName

  defmodule Operation do
    @moduledoc """
    One client change on the controller: a rename, or a correction of its type,
    vendor and model (`correction` holds the `clientInfoCorrection` values).
    """
    @enforce_keys [:client_mac, :name, :summary]
    defstruct [:client_mac, :name, :summary, :correction, action: :rename]

    @type t :: %__MODULE__{
            action: :rename | :correct,
            client_mac: String.t(),
            name: String.t(),
            correction: %{String.t() => String.t()} | nil,
            summary: String.t()
          }
  end

  @type plan :: %{operations: [Operation.t()], skipped: [String.t()]}

  @correction_fields [{"type", "deviceType"}, {"vendor", "vendor"}, {"model", "model"}]

  @doc """
  Plans the changes from the connected clients listed by the controller. Options:
  `:types` (the controller's `typeList`, default none) and `:web_access?` (web
  credentials configured, default `false`).
  """
  @spec plan(DesiredState.t(), [map()], Keyword.t()) :: plan()
  def plan(%DesiredState{client_names: desired}, clients, options \\ []) do
    client_by_mac =
      for %{"mac" => raw_mac} = client <- clients,
          {:ok, mac} <- [MacAddress.normalize(raw_mac)],
          into: %{},
          do: {mac, client}

    Enum.reduce(desired, %{operations: [], skipped: []}, fn client_name, plan ->
      case Map.fetch(client_by_mac, client_name.mac) do
        {:ok, client} ->
          plan
          |> add_rename(client_name, client)
          |> add_correction(client_name, client, options)

        :error ->
          skip(plan, "#{client_name.mac}: not connected to Omada, name not pushed")
      end
    end)
  end

  defp add_rename(plan, %ClientName{name: name}, %{"name" => name}), do: plan

  defp add_rename(plan, client_name, client) do
    add(plan, %Operation{
      client_mac: client["mac"],
      name: client_name.name,
      summary:
        "rename client #{client_name.mac}: #{client["name"] || "unnamed"} → #{client_name.name}"
    })
  end

  defp add_correction(plan, client_name, client, options) do
    correction = correction(client_name, client, Keyword.get(options, :types, []))
    current = current_correction(client)

    cond do
      correction == current ->
        plan

      not Keyword.get(options, :web_access?, false) ->
        skip(
          plan,
          "#{client_name.mac}: type, vendor and model not pushed, " <>
            "set BELGO_OMADA_USERNAME and BELGO_OMADA_PASSWORD"
        )

      true ->
        add(plan, %Operation{
          action: :correct,
          client_mac: client["mac"],
          name: client_name.name,
          correction: correction,
          summary:
            "correct client #{client_name.mac}: #{describe(current)} → #{describe(correction)}"
        })
    end
  end

  # Desired values, falling back to the client's current ones; absent values are left out.
  defp correction(client_name, client, types) do
    desired = %{
      "type" => desired_type(client_name.kind, client, types),
      "vendor" => client_name.vendor,
      "model" => client_name.model
    }

    for {field, client_field} <- @correction_fields,
        value = desired[field] || present(client[client_field]),
        value != nil,
        into: %{},
        do: {field, value}
  end

  # A current type of the same kind is kept (an `iPhone` stays one for a phone).
  defp desired_type(kind, client, types) do
    current = present(client["deviceType"])

    if current != nil and DeviceTypes.to_kind([current]) == kind,
      do: current,
      else: DeviceTypes.to_omada(kind, types)
  end

  defp current_correction(client) do
    for {field, client_field} <- @correction_fields,
        value = present(client[client_field]),
        value != nil,
        into: %{},
        do: {field, value}
  end

  defp describe(correction) do
    Enum.map_join(@correction_fields, " / ", fn {field, _client_field} ->
      correction[field] || "—"
    end)
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp add(plan, operation), do: %{plan | operations: plan.operations ++ [operation]}
  defp skip(plan, message), do: %{plan | skipped: plan.skipped ++ [message]}
end
