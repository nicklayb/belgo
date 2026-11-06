defmodule BelgoWeb.FlashMessage do
  @moduledoc """
  Flash messages with links: `{:linked, segments}` where a segment is a text or a
  `{:link, label, path}` (plain terms, so they survive live redirects).
  `Components.Core.flash_group/1` renders them; plain strings still work.
  """

  @type segment :: String.t() | {:link, String.t(), String.t()}
  @type t :: String.t() | {:linked, [segment()]}

  @doc """
  Turns the `placeholder` of a (translated) message into a link, e.g.
  `linked("patate added to %{device}.", "%{device}", "Hades", "/devices/hades")`.
  """
  @spec linked(String.t(), String.t(), String.t(), String.t()) :: t()
  def linked(message, placeholder, label, path) do
    segments =
      message
      |> String.split(placeholder)
      |> Enum.intersperse({:link, label, path})
      |> Enum.reject(&(&1 == ""))

    {:linked, segments}
  end
end
