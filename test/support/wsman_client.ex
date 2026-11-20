defmodule Belgo.Fixtures.WsmanClient do
  @moduledoc """
  WS-Management without network: Mr. Burns' AMT (account `admin` / `excellent`).
  Answers enumerations of the classes Belgo reads and accepts power changes, which
  are broadcast as `{:amt_power_requested, power_state}` on `topic/0`. Any other
  password is refused like AMT does (`401`).
  """

  @behaviour Belgo.Amt.Wsman.Client

  alias Belgo.Amt.Credentials

  @password "excellent"
  @topic "fixtures:amt"
  @resource_uri ~r{<w:ResourceURI>[^<]*/(?<class>[A-Za-z_]+)</w:ResourceURI>}
  @power_state ~r{<h:PowerState>(?<value>\d+)</h:PowerState>}

  @items_by_class %{
    "CIM_AssociatedPowerManagementService" => [%{"PowerState" => "2"}],
    "CIM_SoftwareIdentity" => [
      %{"InstanceID" => "Flash", "VersionString" => "11.8.55"},
      %{"InstanceID" => "AMT", "VersionString" => "11.8.55"},
      %{"InstanceID" => "Build Number", "VersionString" => "3510"}
    ],
    "CIM_Chassis" => [
      %{
        "Manufacturer" => "Excellent Computers",
        "Model" => "Nuclear 1",
        "SerialNumber" => "SN-1895"
      }
    ],
    "CIM_BIOSElement" => [
      %{
        "Manufacturer" => "Springfield BIOS",
        "Version" => "1.0.7",
        "ReleaseDate" => "<Datetime>1989-12-17T00:00:00Z</Datetime>"
      }
    ],
    "CIM_Chip" => [
      %{
        "ElementName" => "Managed System Processor Chip",
        "Version" => "Intel(R) Core(TM) i5-7500T"
      },
      %{"ElementName" => "Managed System Memory Chip", "Version" => "DDR4"}
    ],
    "CIM_PhysicalMemory" => [%{"Capacity" => "8589934592"}, %{"Capacity" => "8589934592"}]
  }

  @doc "Topic of the power change requests."
  @spec topic() :: String.t()
  def topic, do: @topic

  @impl Belgo.Amt.Wsman.Client
  def post(_target, credentials, envelope) do
    if Credentials.password(credentials) == @password,
      do: {:ok, answer(envelope)},
      else: {:error, :unauthorized}
  end

  defp answer(envelope) do
    %{"class" => class} = Regex.named_captures(@resource_uri, envelope)

    cond do
      String.contains?(envelope, "enumeration/Enumerate") ->
        envelope(
          "<g:EnumerateResponse><g:EnumerationContext>#{class}-context</g:EnumerationContext></g:EnumerateResponse>"
        )

      String.contains?(envelope, "enumeration/Pull") ->
        pull_response(class)

      String.contains?(envelope, "RequestPowerStateChange") ->
        %{"value" => value} = Regex.named_captures(@power_state, envelope)

        Phoenix.PubSub.broadcast(
          Belgo.PubSub,
          @topic,
          {:amt_power_requested, String.to_integer(value)}
        )

        envelope(
          "<g:RequestPowerStateChange_OUTPUT><g:ReturnValue>0</g:ReturnValue></g:RequestPowerStateChange_OUTPUT>"
        )
    end
  end

  defp pull_response(class) do
    items =
      @items_by_class
      |> Map.get(class, [])
      |> Enum.map_join(fn fields ->
        "<h:#{class}>" <>
          Enum.map_join(fields, fn {name, value} -> "<h:#{name}>#{value}</h:#{name}>" end) <>
          "</h:#{class}>"
      end)

    envelope("<g:PullResponse><g:Items>#{items}</g:Items><g:EndOfSequence/></g:PullResponse>")
  end

  defp envelope(body) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<a:Envelope xmlns:a="http://www.w3.org/2003/05/soap-envelope" ) <>
      ~s(xmlns:g="http://schemas.xmlsoap.org/ws/2004/09/enumeration" ) <>
      ~s(xmlns:h="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/">) <>
      "<a:Header/><a:Body>#{body}</a:Body></a:Envelope>"
  end
end
