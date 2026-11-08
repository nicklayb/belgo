defmodule BelgoWeb.ConnCase do
  @moduledoc """
  Test case for tests requiring a connection. The application inventory is reset to
  `Belgo.Fixtures.snapshot/0` before each test, so these tests cannot be async.
  """

  use ExUnit.CaseTemplate

  alias Belgo.Inventory.Snapshot
  alias Belgo.Inventory.Storage.YamlDirectory

  using do
    quote do
      @endpoint BelgoWeb.Endpoint

      use BelgoWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import BelgoWeb.ConnCase
    end
  end

  @live_view_exit_timeout 1_000

  setup _tags do
    reset_inventory()

    test_pid = self()
    on_exit(fn -> await_live_views(test_pid) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  # A LiveView of the test can still be closing once the test is over: its
  # `terminate/2` may save (the plan editor saves pending changes) and must not
  # write into the next test's freshly reset inventory.
  defp await_live_views(test_pid) do
    monitors =
      for pid <- Process.list(),
          {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
          match?({Phoenix.LiveView, _, _}, dictionary[:"$process_label"]),
          test_pid in Keyword.get(dictionary, :"$callers", []),
          do: Process.monitor(pid)

    for monitor <- monitors do
      receive do
        {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
      after
        @live_view_exit_timeout -> ExUnit.Assertions.flunk("a LiveView did not stop")
      end
    end
  end

  @doc "Writes the fixture inventory to the application storage and reloads it."
  def reset_inventory do
    {YamlDirectory, options} = Application.fetch_env!(:belgo, Belgo.Inventory)[:storage]

    for collection <- Snapshot.collections() do
      :ok = YamlDirectory.save(options, Belgo.Fixtures.snapshot(), collection)
    end

    File.rm_rf!(providers_path())
    :ok = Belgo.Inventory.reload()
    Belgo.Discovery.refresh()
    %Belgo.Discovery.State{providers: []} = Belgo.Discovery.state()
  end

  @doc "Enables the fixture OPNsense provider in write mode and waits for its first pull."
  def enable_opnsense do
    enable_providers(
      "version: 1\nproviders:\n  opnsense:\n    mode: write\n    url: https://opnsense.springfield.lan\n"
    )
  end

  @doc "Enables the Home Assistant provider (fake client) and waits for its first pull."
  def enable_home_assistant do
    enable_providers(
      "version: 1\nproviders:\n  home_assistant:\n    url: https://homeassistant.springfield.lan\n"
    )
  end

  @doc "Writes `providers.yaml` (exactly one provider) and waits for its first pull."
  def enable_providers(content) do
    File.write!(providers_path(), content)

    Belgo.Discovery.subscribe()
    Belgo.Discovery.refresh()

    ExUnit.Assertions.assert_receive(
      {:discovery_changed, %{providers: [%{running?: false, completed_at: %DateTime{}}]}},
      1_000
    )
  end

  defp providers_path do
    {YamlDirectory, options} = Application.fetch_env!(:belgo, Belgo.Inventory)[:storage]
    Path.join(Keyword.fetch!(options, :path), "providers.yaml")
  end
end
