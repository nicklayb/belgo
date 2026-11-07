defmodule BelgoWeb.LocaleTest do
  use ExUnit.Case, async: true

  alias BelgoWeb.Locale

  test "the browser's best supported language wins" do
    assert "fr" == Locale.from_accept_language("fr-CA,fr;q=0.9,en-US;q=0.8,en;q=0.7")
    assert "en" == Locale.from_accept_language("de-DE,en;q=0.5,fr;q=0.3")
    assert "fr" == Locale.from_accept_language("en;q=0.2, fr;q=0.8")
    assert nil == Locale.from_accept_language("de,es")
    assert nil == Locale.from_accept_language(nil)
  end

  test "the user's choice comes first, the default last" do
    assert "en" == Locale.resolve("en", "fr-CA")
    assert "fr" == Locale.resolve(nil, "fr-CA")
    assert "fr" == Locale.resolve("klingon", "fr")
    assert "en" == Locale.resolve(nil, "de")
  end
end
