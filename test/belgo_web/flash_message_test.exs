defmodule BelgoWeb.FlashMessageTest do
  use ExUnit.Case, async: true

  alias BelgoWeb.FlashMessage

  test "turns a placeholder into a link" do
    assert {:linked, ["patate added to ", {:link, "Skynet", "/devices/skynet"}, "."]} ==
             FlashMessage.linked(
               "patate added to %{device}.",
               "%{device}",
               "Skynet",
               "/devices/skynet"
             )

    assert {:linked, [{:link, "Skynet", "/devices/skynet"}, " is awake."]} ==
             FlashMessage.linked("%{device} is awake.", "%{device}", "Skynet", "/devices/skynet")
  end
end
