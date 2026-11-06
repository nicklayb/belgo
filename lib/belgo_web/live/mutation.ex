defmodule BelgoWeb.Live.Mutation do
  @moduledoc "Helpers turning use case results into LiveView responses."

  use Gettext, backend: BelgoWeb.Gettext

  alias BelgoWeb.Format

  @doc "Use case options on behalf of the connected user."
  @spec options(Phoenix.LiveView.Socket.t()) :: Keyword.t()
  def options(socket), do: [user: socket.assigns.current_user]

  @doc "Describes a failed use case for a flash message."
  @spec describe_error(any()) :: String.t()
  def describe_error({:error, _step, {:referenced, references}, _changes}),
    do: Format.references(references)

  def describe_error({:error, _step, :not_found, _changes}),
    do: gettext("This record no longer exists.")

  def describe_error({:error, :persist, reason, _changes}),
    do: gettext("Unable to write the inventory files: %{reason}", reason: inspect(reason))

  def describe_error({:error, :unauthorized}), do: gettext("You are not allowed to do that.")
  def describe_error(error), do: gettext("Unexpected error: %{error}", error: inspect(error))
end
