defmodule Belgo.Amt.Credentials do
  @moduledoc """
  The AMT account typed by the user for one action, never stored. The password is
  kept in a closure and hidden from `inspect/2`, so a crash report or a log line
  printing the struct (or the process arguments holding it) never shows it.
  """

  @default_username "admin"

  @derive {Inspect, except: [:password]}
  @enforce_keys [:username, :password]
  defstruct [:username, :password]

  @type t :: %__MODULE__{username: String.t(), password: (-> String.t())}

  @doc "The default AMT account name."
  @spec default_username() :: String.t()
  def default_username, do: @default_username

  @doc "Builds credentials; a blank username means the default one (`admin`)."
  @spec new(String.t() | nil, String.t()) :: t()
  def new(username, password) when is_binary(password) do
    username = if username in [nil, ""], do: @default_username, else: String.trim(username)
    %__MODULE__{username: username, password: fn -> password end}
  end

  @doc "The password."
  @spec password(t()) :: String.t()
  def password(%__MODULE__{password: password}), do: password.()
end
