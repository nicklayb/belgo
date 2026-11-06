defmodule Belgo.Network.MacAddress do
  @moduledoc "Normalisation of MAC addresses to the lowercase, colon separated form."

  @separators ~r/[:\-\.\s]/
  @hexadecimal_mac ~r/\A[0-9a-f]{12}\z/
  @octet_length 2

  @doc "Normalises a MAC address (`AA-BB-CC-DD-EE-FF` becomes `aa:bb:cc:dd:ee:ff`)."
  @spec normalize(any()) :: {:ok, String.t()} | :error
  def normalize(value) when is_binary(value) do
    hexadecimal =
      value
      |> String.downcase()
      |> String.replace(@separators, "")

    if Regex.match?(@hexadecimal_mac, hexadecimal) do
      {:ok, format_octets(hexadecimal)}
    else
      :error
    end
  end

  def normalize(_value), do: :error

  defp format_octets(hexadecimal) do
    hexadecimal
    |> String.graphemes()
    |> Enum.chunk_every(@octet_length)
    |> Enum.map_join(":", &Enum.join/1)
  end
end
