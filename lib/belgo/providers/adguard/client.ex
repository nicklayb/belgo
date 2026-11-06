defmodule Belgo.Providers.Adguard.Client do
  @moduledoc "Behaviour of the AdGuard Home API access, so tests never reach the network."

  alias Belgo.Providers.Adguard.Config

  @doc "Gets a JSON document."
  @callback get(Config.t(), path :: String.t()) :: {:ok, any()} | {:error, any()}

  @doc "Sends a JSON body with `:post` or `:put`; success bodies are often empty."
  @callback request(Config.t(), :post | :put, path :: String.t(), body :: map()) ::
              {:ok, any()} | {:error, any()}
end
