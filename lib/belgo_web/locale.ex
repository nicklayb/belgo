defmodule BelgoWeb.Locale do
  @moduledoc """
  The interface language. Supported locales are English (default) and French. The
  browser chooses (`Accept-Language`) unless the user picked one on the settings
  page: that choice lives in the browser's localStorage (`belgo:locale`), mirrored
  in the `belgo_locale` cookie so the first render already uses it, and sent as the
  LiveView `locale` connect param. Pure functions.
  """

  @supported ~w(en fr)
  @default "en"
  @cookie "belgo_locale"

  @doc "Supported locales."
  @spec supported() :: [String.t()]
  def supported, do: @supported

  @doc "The locale used when nothing else matches."
  @spec default() :: String.t()
  def default, do: @default

  @doc "Name of the cookie mirroring the user's choice."
  @spec cookie() :: String.t()
  def cookie, do: @cookie

  @doc "The value when it is a supported locale, else `nil`."
  @spec supported(term()) :: String.t() | nil
  def supported(locale) when locale in @supported, do: locale
  def supported(_locale), do: nil

  @doc """
  The best supported locale of an `Accept-Language` header (by quality, then order;
  `fr-CA` matches `fr`), else `nil`.
  """
  @spec from_accept_language(String.t() | nil) :: String.t() | nil
  def from_accept_language(nil), do: nil

  def from_accept_language(header) when is_binary(header) do
    header
    |> String.split(",", trim: true)
    |> Enum.with_index()
    |> Enum.map(fn {entry, position} -> parse_entry(entry, position) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_language, quality, position} -> {-quality, position} end)
    |> Enum.find_value(fn {language, _quality, _position} -> supported(language) end)
  end

  @doc "The locale to use: the user's choice when supported, else the browser's, else the default."
  @spec resolve(String.t() | nil, String.t() | nil) :: String.t()
  def resolve(choice, accept_language),
    do: supported(choice) || from_accept_language(accept_language) || @default

  defp parse_entry(entry, position) do
    [tag | parameters] =
      entry
      |> String.trim()
      |> String.split(";")

    language =
      tag
      |> String.trim()
      |> String.downcase()
      |> String.split("-")
      |> hd()

    if language == "", do: nil, else: {language, quality(parameters), position}
  end

  defp quality(parameters) do
    Enum.find_value(parameters, 1.0, fn parameter ->
      with "q=" <> value <- String.trim(parameter),
           {quality, _rest} <- Float.parse(value) do
        quality
      else
        _other -> nil
      end
    end)
  end
end
