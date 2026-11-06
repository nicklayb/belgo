defmodule BelgoWeb.Plugs.Theme do
  @moduledoc """
  Assigns `theme` (`"auto"`, `"light"` or `"dark"`, from `config.yaml`) for the root
  layout, which sets it on `<html data-theme>`. Read on every page load, so a change
  applies on the next reload.
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(conn, _options), do: assign(conn, :theme, Atom.to_string(Belgo.Config.current().theme))
end
