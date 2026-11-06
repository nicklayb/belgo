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

  setup _tags do
    reset_inventory()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
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
