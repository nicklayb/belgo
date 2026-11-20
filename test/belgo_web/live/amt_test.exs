defmodule BelgoWeb.AmtLiveTest do
  use BelgoWeb.ConnCase, async: false

  @moduletag :capture_log

  alias Belgo.Amt.Sol
  alias Belgo.Fixtures.WsmanClient

  # The static user of the test environment.
  @username "admin"

  setup do
    on_exit(fn ->
      for %{device_id: device_id} <- Sol.sessions(@username), do: Sol.close(@username, device_id)
    end)
  end

  defp burns_node_page(conn) do
    {:ok, view, _html} = live(conn, ~p"/devices/burns-node")
    assert eventually(fn -> has_element?(view, "#amt", "Intel AMT 11.8.55.3510") end)
    view
  end

  defp submit_password(view, password, extra \\ %{}) do
    view
    |> form("#amt-modal form", amt: Map.merge(%{username: "admin", password: password}, extra))
    |> render_submit()
  end

  test "a device without AMT has no AMT card", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices/smithers")
    refute has_element?(view, "#amt")
  end

  test "reads the status with the typed password, never kept", %{conn: conn} do
    view = burns_node_page(conn)

    render_click(element(view, "#amt-request-status"))
    assert has_element?(view, "#amt-modal", "Read status")

    html = submit_password(view, "excellent")
    refute html =~ "excellent"
    refute has_element?(view, "#amt-modal")

    assert eventually(fn -> has_element?(view, "#amt-info", "Excellent Computers") end)
    assert has_element?(view, "#amt-info", "16 GiB")
    assert has_element?(view, "#amt-power-state", "On")
    refute has_element?(view, "#amt-vulnerable")
  end

  test "a refused password is reported", %{conn: conn} do
    view = burns_node_page(conn)

    render_click(element(view, "#amt-request-status"))
    submit_password(view, "mmm-donuts")

    assert eventually(fn -> render(view) =~ "AMT refused the account." end)
  end

  test "an empty password is asked again", %{conn: conn} do
    view = burns_node_page(conn)

    render_click(element(view, "#amt-request-status"))
    submit_password(view, "")

    assert has_element?(view, "#amt-error", "Type the AMT password.")
  end

  test "power actions ask for confirmation, critical devices twice", %{conn: conn} do
    Phoenix.PubSub.subscribe(Belgo.PubSub, WsmanClient.topic())
    view = burns_node_page(conn)

    render_click(element(view, "#amt-request-power_cycle"))
    assert has_element?(view, "#amt-modal", "Power cycle Burns Node?")
    refute has_element?(view, "#amt-critical-confirmed")

    submit_password(view, "excellent")
    assert_receive {:amt_power_requested, 5}
    assert eventually(fn -> render(view) =~ "Power cycle sent to Burns Node" end)

    {:ok, _device} =
      Belgo.Inventory.update(:devices, "burns-node", %{"critical" => "true"},
        user: %Belgo.Accounts.User{username: @username}
      )

    view = burns_node_page(conn)

    render_click(element(view, "#amt-request-power_off"))
    assert has_element?(view, "#amt-critical-confirmed")

    submit_password(view, "excellent")
    assert has_element?(view, "#amt-error", "Confirm the action on this critical device.")
    refute_received {:amt_power_requested, _value}

    submit_password(view, "excellent", %{critical_confirmed: "true"})
    assert_receive {:amt_power_requested, 8}
  end

  test "the console opens from the device page and survives leaving it", %{conn: conn} do
    view = burns_node_page(conn)

    render_click(element(view, "#amt-request-console"))

    assert {:error, {:live_redirect, %{to: "/devices/burns-node/console"}}} =
             submit_password(view, "excellent")

    assert Sol.open?(@username, "burns-node")

    {:ok, console, _html} = live(conn, ~p"/devices/burns-node/console")
    assert has_element?(console, "[phx-hook=AmtConsole]")

    assert eventually(fn -> scrollback() =~ "connected now" end)
    render_hook(console, "attach", %{})
    assert_reply(console, %{data: data})
    assert Base.decode64!(data) =~ "connected now"

    render_hook(console, "input", %{data: Base.encode64("release the hounds\n")})
    assert_push_event(console, "amt-output", %{data: output})
    assert Base.decode64!(output) =~ "release the hounds"

    # The device page now links back to the open console.
    {:ok, view, _html} = live(conn, ~p"/devices/burns-node")
    assert eventually(fn -> has_element?(view, "#amt-console-open") end)

    render_click(element(console, "#amt-console-close"))
    assert eventually(fn -> has_element?(console, "#amt-console-closed", "Console closed.") end)
    refute Sol.open?(@username, "burns-node")
  end

  test "the console page asks the password when no console is open", %{conn: conn} do
    {:ok, console, _html} = live(conn, ~p"/devices/burns-node/console")
    assert eventually(fn -> has_element?(console, "#amt-console-connect") end)
    refute has_element?(console, "[phx-hook=AmtConsole]")

    render_click(element(console, "#amt-console-connect"))
    submit_password(console, "excellent")

    assert has_element?(console, "[phx-hook=AmtConsole]")
    assert Sol.open?(@username, "burns-node")
  end

  defp scrollback do
    {:ok, content, _offset} = Sol.attach(@username, "burns-node")
    content
  end

  defp eventually(check, attempts \\ 40) do
    cond do
      check.() -> true
      attempts == 0 -> false
      true -> Process.sleep(25) && eventually(check, attempts - 1)
    end
  end
end
