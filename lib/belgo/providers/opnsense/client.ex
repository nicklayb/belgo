defmodule Belgo.Providers.Opnsense.Client do
  @moduledoc "Behaviour of the OPNsense API access, so tests never reach the network."

  alias Belgo.Providers.Opnsense.Config

  @doc "Calls a `search_*` endpoint and returns every row."
  @callback search(Config.t(), path :: String.t()) :: {:ok, [map()]} | {:error, any()}

  @doc "Posts a JSON body and returns the decoded response."
  @callback post(Config.t(), path :: String.t(), body :: map()) :: {:ok, map()} | {:error, any()}
end
