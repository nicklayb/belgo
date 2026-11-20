defmodule Belgo.Amt.Wsman.Client do
  @moduledoc """
  Behaviour of the WS-Management transport, so tests never reach an AMT
  (`config :belgo, Belgo.Amt, wsman_client: …`).
  """

  alias Belgo.Amt.Credentials
  alias Belgo.Amt.Target

  @type error :: :unauthorized | {:http_status, pos_integer()} | {:request_failed, String.t()}

  @doc "Posts a SOAP envelope to `/wsman`, authenticated with HTTP Digest, and returns the answer."
  @callback post(Target.t(), Credentials.t(), envelope :: String.t()) ::
              {:ok, String.t()} | {:error, error()}
end
