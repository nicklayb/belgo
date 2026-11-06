defmodule BelgoWeb.Health.Controller do
  @moduledoc "Unauthenticated liveness endpoint for Kubernetes probes."

  use BelgoWeb, :controller

  @doc "Responds `ok` while the application runs."
  def show(conn, _params), do: text(conn, "ok")
end
