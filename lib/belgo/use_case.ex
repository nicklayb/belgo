defmodule Belgo.UseCase do
  @moduledoc """
  Mutations of Belgo are `Box.UseCase`s. Their `Ecto.Multi` is run against the
  inventory by `Belgo.Inventory.Transaction` instead of a database.

  Options:

    * `:user` – the `Belgo.Accounts.User` performing the change, or `:system`
    * `:transaction` – options given to `Belgo.Inventory.Transaction.run/2`
  """

  alias Belgo.Accounts.User

  defmacro __using__(_options) do
    quote do
      use Box.UseCase

      import Belgo.UseCase, only: [authorize: 1]
    end
  end

  @type use_case :: module()
  @type params :: any()
  @type options :: Keyword.t()

  @doc "Executes a use case, raising on failure."
  @spec execute!(use_case(), params(), options()) :: any()
  def execute!(module, params, options \\ []) do
    Box.UseCase.execute!(module, params, with_default_options(options))
  end

  @doc "Executes a use case."
  @spec execute(use_case(), params(), options()) :: any()
  def execute(module, params, options \\ []) do
    Box.UseCase.execute(module, params, with_default_options(options))
  end

  @doc "Ensures the use case is run on behalf of someone."
  @spec authorize(options()) :: {:ok, User.t() | :system} | {:error, :unauthorized}
  def authorize(use_case_options) do
    case Keyword.get(use_case_options, :user) do
      %User{} = user -> {:ok, user}
      :system -> {:ok, :system}
      _missing -> {:error, :unauthorized}
    end
  end

  defp with_default_options(options) do
    Keyword.put(options, :run, &Belgo.Inventory.Transaction.run/2)
  end
end
