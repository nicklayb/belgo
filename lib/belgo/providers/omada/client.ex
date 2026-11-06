defmodule Belgo.Providers.Omada.Client do
  @moduledoc "Behaviour of the Omada controller access, so tests never reach the network."

  alias Belgo.Providers.Omada.Config

  @type session :: map()

  @doc "Obtains an access token and resolves the configured site."
  @callback open(Config.t()) :: {:ok, session()} | {:error, any()}

  @doc "Returns the devices of the site (gateway, switches, access points) with their uplink."
  @callback devices(session()) :: {:ok, [map()]} | {:error, any()}

  @doc "Returns the connected clients of the site."
  @callback clients(session()) :: {:ok, [map()]} | {:error, any()}

  @doc "Renames a client, `mac` being the address as written by the controller."
  @callback rename_client(session(), mac :: String.t(), name :: String.t()) ::
              {:ok, any()} | {:error, any()}
end
