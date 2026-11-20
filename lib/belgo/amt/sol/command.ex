defmodule Belgo.Amt.Sol.Command do
  @moduledoc """
  The amtterm command line of a session (pure). The password only goes to the
  environment (`AMT_PASSWORD`), never to the arguments (visible in `ps`). TLS
  (16995) passes `amt.ca_file` with `-C`; amtterm then verifies the certificate
  against it (TLS 1.2, host name not checked).
  """

  alias Belgo.Amt.Credentials
  alias Belgo.Amt.Target

  @password_variable ~c"AMT_PASSWORD"

  @doc "The arguments of amtterm: account, optional CA file, host and redirection port."
  @spec arguments(Target.t(), Credentials.t()) :: [String.t()]
  def arguments(%Target{} = target, %Credentials{} = credentials) do
    tls_arguments = if target.redirection_tls?, do: ["-C", target.ca_file], else: []

    ["-u", credentials.username] ++
      tls_arguments ++ [target.address, Integer.to_string(target.redirection_port)]
  end

  @doc "The environment of amtterm (charlists, as `Port.open/2` wants them)."
  @spec environment(Credentials.t()) :: [{charlist(), charlist()}]
  def environment(%Credentials{} = credentials),
    do: [{@password_variable, String.to_charlist(Credentials.password(credentials))}]
end
