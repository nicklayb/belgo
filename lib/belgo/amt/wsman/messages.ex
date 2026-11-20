defmodule Belgo.Amt.Wsman.Messages do
  @moduledoc """
  Builds the WS-Management SOAP envelopes Belgo sends to AMT (pure): enumerating a
  class (`Enumerate` then `Pull`) and the power state change.

  Shapes follow Intel's Open AMT `go-wsman-messages` and MeshCommander; **not yet
  verified against real hardware**.
  """

  @cim_schema "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/"
  @amt_schema "http://intel.com/wbem/wscim/1/amt-schema/1/"
  @enumeration "http://schemas.xmlsoap.org/ws/2004/09/enumeration"
  @addressing "http://schemas.xmlsoap.org/ws/2004/08/addressing"
  @wsman "http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd"
  @anonymous_address "http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous"
  @operation_timeout "PT60S"
  @maximum_pulled_elements 999
  @maximum_pulled_characters 99_999

  @doc "The resource URI of a class: `CIM_*` in the DMTF schema, `AMT_*` in Intel's."
  @spec resource_uri(String.t()) :: String.t()
  def resource_uri("AMT_" <> _rest = class), do: @amt_schema <> class
  def resource_uri(class), do: @cim_schema <> class

  @doc "Starts enumerating the instances of a class."
  @spec enumerate(String.t(), pos_integer()) :: String.t()
  def enumerate(class, message_id) do
    envelope(
      "#{@enumeration}/Enumerate",
      resource_uri(class),
      message_id,
      ~s(<Enumerate xmlns="#{@enumeration}"/>)
    )
  end

  @doc "Pulls the instances of an enumeration context."
  @spec pull(String.t(), String.t(), pos_integer()) :: String.t()
  def pull(class, context, message_id) do
    envelope(
      "#{@enumeration}/Pull",
      resource_uri(class),
      message_id,
      ~s(<Pull xmlns="#{@enumeration}"><EnumerationContext>#{escape(context)}</EnumerationContext>) <>
        "<MaxElements>#{@maximum_pulled_elements}</MaxElements>" <>
        "<MaxCharacters>#{@maximum_pulled_characters}</MaxCharacters></Pull>"
    )
  end

  @doc "Asks `CIM_PowerManagementService` to move the managed system to a power state."
  @spec request_power_state_change(pos_integer(), pos_integer()) :: String.t()
  def request_power_state_change(power_state, message_id) do
    service = resource_uri("CIM_PowerManagementService")

    envelope(
      "#{service}/RequestPowerStateChange",
      service,
      message_id,
      ~s(<h:RequestPowerStateChange_INPUT xmlns:h="#{service}">) <>
        "<h:PowerState>#{power_state}</h:PowerState>" <>
        "<h:ManagedElement>" <>
        ~s(<Address xmlns="#{@addressing}">#{@addressing}</Address>) <>
        ~s(<ReferenceParameters xmlns="#{@addressing}">) <>
        ~s(<ResourceURI xmlns="#{@wsman}">#{resource_uri("CIM_ComputerSystem")}</ResourceURI>) <>
        ~s(<SelectorSet xmlns="#{@wsman}">) <>
        ~s(<Selector Name="CreationClassName">CIM_ComputerSystem</Selector>) <>
        ~s(<Selector Name="Name">ManagedSystem</Selector>) <>
        "</SelectorSet></ReferenceParameters></h:ManagedElement>" <>
        "</h:RequestPowerStateChange_INPUT>"
    )
  end

  defp envelope(action, resource_uri, message_id, body) do
    ~s(<?xml version="1.0" encoding="utf-8"?>) <>
      ~s(<Envelope xmlns="http://www.w3.org/2003/05/soap-envelope" ) <>
      ~s(xmlns:a="#{@addressing}" xmlns:w="#{@wsman}">) <>
      "<Header>" <>
      "<a:Action>#{action}</a:Action>" <>
      "<a:To>/wsman</a:To>" <>
      "<w:ResourceURI>#{resource_uri}</w:ResourceURI>" <>
      "<a:MessageID>#{message_id}</a:MessageID>" <>
      "<a:ReplyTo><a:Address>#{@anonymous_address}</a:Address></a:ReplyTo>" <>
      "<w:OperationTimeout>#{@operation_timeout}</w:OperationTimeout>" <>
      "</Header>" <>
      "<Body>#{body}</Body></Envelope>"
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
