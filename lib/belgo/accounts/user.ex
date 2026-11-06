defmodule Belgo.Accounts.User do
  @moduledoc "The authenticated person, as reported by the authentication proxy."

  @enforce_keys [:username]
  defstruct [:username, :name, :email, groups: []]

  @type t :: %__MODULE__{
          username: String.t(),
          name: String.t() | nil,
          email: String.t() | nil,
          groups: [String.t()]
        }

  @doc "Returns the best name to display."
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name
  def display_name(%__MODULE__{username: username}), do: username
end
