defmodule Belgo.Config.Amt do
  @moduledoc """
  Settings of Intel AMT (milliseconds): a console session closes after
  `idle_timeout` without input, WS-Management requests wait at most `timeout`.
  `ca_file` (optional) is the PEM CA certificate of the AMT TLS ports (16993 / 16995),
  used only when the plain ports (16992 / 16994) are closed.
  """

  @default_idle_timeout_milliseconds 15 * 60_000
  @default_timeout_milliseconds 10_000

  defstruct idle_timeout: @default_idle_timeout_milliseconds,
            timeout: @default_timeout_milliseconds,
            ca_file: nil

  @type t :: %__MODULE__{
          idle_timeout: pos_integer(),
          timeout: pos_integer(),
          ca_file: Path.t() | nil
        }
end
