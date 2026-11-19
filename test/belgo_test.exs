defmodule BelgoTest do
  use ExUnit.Case, async: true

  @version_path Path.expand("../VERSION", __DIR__)

  test "version/0 is the content of the VERSION file" do
    version = File.read!(@version_path)
    assert Belgo.version() == String.trim(version)
  end
end
