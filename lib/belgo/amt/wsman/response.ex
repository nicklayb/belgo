defmodule Belgo.Amt.Wsman.Response do
  @moduledoc """
  Reads WS-Management SOAP answers (pure, with OTP's `:xmerl`): SOAP faults, the
  enumeration context, pulled instances as maps of field → text, and the
  `ReturnValue` of a method. Namespace prefixes are ignored: AMT names them freely.
  """

  require Record

  Record.defrecordp(
    :xml_element,
    :xmlElement,
    Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(
    :xml_text,
    :xmlText,
    Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl")
  )

  @typedoc "An element: local name, children elements and its whole text."
  @type element :: %{name: String.t(), children: [element()], text: String.t()}

  @doc "Parses an answer into its `Body` element, or the reason of its SOAP fault."
  @spec body(String.t()) :: {:ok, element()} | {:error, {:fault, String.t()} | :invalid_xml}
  def body(xml) when is_binary(xml) do
    with {:ok, envelope} <- parse(xml),
         %{} = body <- child(envelope, "Body") do
      case child(body, "Fault") do
        nil -> {:ok, body}
        fault -> {:error, {:fault, fault_reason(fault)}}
      end
    else
      _invalid -> {:error, :invalid_xml}
    end
  end

  @doc "The `EnumerationContext` of an `EnumerateResponse` body."
  @spec enumeration_context(element()) :: {:ok, String.t()} | :error
  def enumeration_context(body) do
    case find(body, "EnumerationContext") do
      %{text: context} when context != "" -> {:ok, context}
      _missing -> :error
    end
  end

  @doc "The instances of a `PullResponse` body, each a map of its fields (field → text)."
  @spec items(element()) :: [%{String.t() => String.t()}]
  def items(body) do
    case find(body, "Items") do
      nil -> []
      items -> Enum.map(items.children, &fields/1)
    end
  end

  @doc "The `ReturnValue` of a method answer (`<Method>_OUTPUT`)."
  @spec return_value(element()) :: {:ok, integer()} | :error
  def return_value(body) do
    with %{text: text} <- find(body, "ReturnValue"),
         {value, ""} <- Integer.parse(text) do
      {:ok, value}
    else
      _missing -> :error
    end
  end

  defp fields(%{children: children}),
    do: Map.new(children, &{&1.name, &1.text})

  defp fault_reason(fault) do
    case find(fault, "Text") || find(fault, "Value") do
      %{text: text} -> text
      nil -> fault.text
    end
  end

  defp child(%{children: children}, name), do: Enum.find(children, &(&1.name == name))

  # Depth-first search of the first element named `name`.
  defp find(%{name: name} = element, name), do: element

  defp find(%{children: children}, name),
    do: Enum.find_value(children, &find(&1, name))

  defp parse(xml) do
    {document, _rest} =
      xml
      |> String.to_charlist()
      |> :xmerl_scan.string(quiet: true)

    {:ok, convert(document)}
  catch
    :exit, _reason -> :error
  end

  defp convert(xml_element(name: name, content: content)) do
    children = for xml_element() = child <- content, do: convert(child)

    %{
      name: local_name(name),
      children: children,
      text: String.trim(text(content))
    }
  end

  defp text(content) do
    Enum.map_join(content, fn
      xml_text(value: value) -> List.to_string(value)
      xml_element(content: nested) -> text(nested)
      _other -> ""
    end)
  end

  defp local_name(name) do
    name
    |> Atom.to_string()
    |> String.split(":")
    |> List.last()
  end
end
