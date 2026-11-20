defmodule Belgo.Amt do
  @moduledoc """
  Intel AMT of the devices: detected by the port scan (`Belgo.Amt.Probe`, live, never
  persisted), read and powered through WS-Management (`status/3`, `power/4`), and
  reached as a serial console (`Belgo.Amt.Sol`).

  The account is typed by the user for every action and never stored nor logged
  (`Belgo.Amt.Credentials`). Logs: `debug` when a request starts, `info` on success,
  `error` on failure, as `[amt] [<operation>] [<device>] [<user>]`.

  The transport is configurable (`config :belgo, Belgo.Amt, wsman_client: …`, default
  `Belgo.Amt.Wsman.HttpClient`) so tests never reach the network.
  """

  alias Belgo.Amt.Credentials
  alias Belgo.Amt.Detection
  alias Belgo.Amt.Info
  alias Belgo.Amt.Power
  alias Belgo.Amt.Target
  alias Belgo.Amt.Wsman.HttpClient
  alias Belgo.Amt.Wsman.Messages
  alias Belgo.Amt.Wsman.Response
  alias Belgo.PortScan.AddressScan

  require Logger

  # Errors after which reading other classes is pointless (the account or the
  # connection fails, not the class).
  @fatal_errors [:unauthorized, :ca_file_missing]

  @type error ::
          :unauthorized
          | :ca_file_missing
          | {:fault, String.t()}
          | {:return_value, integer()}
          | {:http_status, pos_integer()}
          | {:request_failed, String.t()}
          | :invalid_xml
          | :invalid_answer

  @doc "The first AMT detected among the scans of the addresses, `nil` without one."
  @spec detection(%{String.t() => AddressScan.t()}, [String.t()]) :: Detection.t() | nil
  def detection(address_scans, addresses) do
    Enum.find_value(addresses, fn address ->
      case Map.get(address_scans, address) do
        %AddressScan{amt: %Detection{} = detection} -> detection
        _other -> nil
      end
    end)
  end

  @doc """
  Reads the power state and the information of the machine. The power state is read
  first: a refused account stops there; other classes failing are left empty.

  Options: `:client`, `:device_id` and `:username` (logs).
  """
  @spec status(Target.t(), Credentials.t(), Keyword.t()) :: {:ok, Info.t()} | {:error, error()}
  def status(%Target{} = target, %Credentials{} = credentials, options \\ []) do
    log_prefix = log_prefix("status", options)
    Logger.debug("#{log_prefix} reading #{target.address}")

    with :ok <- Target.check_tls(target, :wsman),
         {:ok, power_items} <- pull(target, credentials, Info.power_class(), options),
         {:ok, items_by_class} <- pull_classes(target, credentials, options) do
      info = Info.build(Map.put(items_by_class, Info.power_class(), power_items))
      Logger.info("#{log_prefix} read, power #{info.power_state}")
      {:ok, info}
    else
      {:error, reason} = error ->
        Logger.error("#{log_prefix} failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Asks AMT to power the machine on, off, reset it or cycle its power, then reads the
  power state reported right after (it may still be changing).

  Options: `:client`, `:device_id` and `:username` (logs).
  """
  @spec power(Target.t(), Credentials.t(), Power.action(), Keyword.t()) ::
          {:ok, Power.state()} | {:error, error()}
  def power(%Target{} = target, %Credentials{} = credentials, action, options \\ []) do
    log_prefix = log_prefix("power", options) <> " [#{action}]"
    Logger.debug("#{log_prefix} requesting on #{target.address}")

    envelope =
      Messages.request_power_state_change(Power.requested_power_state(action), message_id())

    with :ok <- Target.check_tls(target, :wsman),
         {:ok, body} <- call(target, credentials, envelope, options),
         {:ok, return_value} <- return_value(body),
         :ok <- check_return_value(return_value),
         {:ok, power_items} <- pull(target, credentials, Info.power_class(), options) do
      state = Info.power_state(power_items)
      Logger.info("#{log_prefix} done, power #{state}")
      {:ok, state}
    else
      {:error, reason} = error ->
        Logger.error("#{log_prefix} failed: #{inspect(reason)}")
        error
    end
  end

  defp pull_classes(target, credentials, options) do
    Enum.reduce_while(Info.classes(), {:ok, %{}}, fn class, {:ok, items_by_class} ->
      case pull(target, credentials, class, options) do
        {:ok, items} -> {:cont, {:ok, Map.put(items_by_class, class, items)}}
        {:error, reason} = error when reason in @fatal_errors -> {:halt, error}
        {:error, {:request_failed, _message}} = error -> {:halt, error}
        {:error, _reason} -> {:cont, {:ok, items_by_class}}
      end
    end)
  end

  defp pull(target, credentials, class, options) do
    with {:ok, body} <-
           call(target, credentials, Messages.enumerate(class, message_id()), options),
         {:ok, context} <- enumeration_context(body),
         {:ok, body} <-
           call(target, credentials, Messages.pull(class, context, message_id()), options) do
      {:ok, Response.items(body)}
    end
  end

  defp call(target, credentials, envelope, options) do
    client = Keyword.get(options, :client, client())

    with {:ok, answer} <- client.post(target, credentials, envelope),
         do: Response.body(answer)
  end

  defp enumeration_context(body) do
    case Response.enumeration_context(body) do
      {:ok, context} -> {:ok, context}
      :error -> {:error, :invalid_answer}
    end
  end

  defp return_value(body) do
    case Response.return_value(body) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_answer}
    end
  end

  defp check_return_value(value) do
    if Power.successful?(value), do: :ok, else: {:error, {:return_value, value}}
  end

  defp message_id, do: System.unique_integer([:positive, :monotonic])

  defp log_prefix(operation, options) do
    "[amt] [#{operation}] [#{Keyword.get(options, :device_id, "-")}] " <>
      "[#{Keyword.get(options, :username, "-")}]"
  end

  defp client do
    :belgo
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:wsman_client, HttpClient)
  end
end
