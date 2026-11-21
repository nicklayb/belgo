defmodule Belgo.Providers.Proxmox.Client do
  @moduledoc "Behaviour of the Proxmox VE API access, so tests never reach the network."

  alias Belgo.Providers.Proxmox.Config

  @doc "Gets an API path (under `/api2/json`) and returns its `data`."
  @callback get(Config.t(), path :: String.t()) :: {:ok, any()} | {:error, any()}
end
