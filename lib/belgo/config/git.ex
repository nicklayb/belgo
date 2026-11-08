defmodule Belgo.Config.Git do
  @moduledoc """
  Versioning of the data directory with git (durations in milliseconds).

  Present when `config.yaml` has a `git` key: the directory becomes a repository and
  changes are committed once the files are left alone for `commit_delay`. With a
  `remote`, commits are pushed every `push_interval` (never pulled, never forced).
  `branch` is the remote branch, the current local branch when `nil`.

  `BELGO_GIT_REMOTE` and `BELGO_GIT_BRANCH` override `remote` and `branch`: the data
  repository (and its `config.yaml`) is shared by every instance, but each one pushes
  to its own branch (`with_environment/2`).
  """

  @default_commit_delay_milliseconds 5 * 60_000
  @default_push_interval_milliseconds 60 * 60_000
  @default_author_name "Belgo"
  @default_author_email "belgo@localhost"
  @environment_overrides [remote: "BELGO_GIT_REMOTE", branch: "BELGO_GIT_BRANCH"]

  defstruct commit_delay: @default_commit_delay_milliseconds,
            push_interval: @default_push_interval_milliseconds,
            author_name: @default_author_name,
            author_email: @default_author_email,
            remote: nil,
            branch: nil

  @type t :: %__MODULE__{
          commit_delay: non_neg_integer(),
          push_interval: pos_integer(),
          author_name: String.t(),
          author_email: String.t(),
          remote: String.t() | nil,
          branch: String.t() | nil
        }

  @doc "Default push interval, also used to check again when git is not configured."
  @spec default_push_interval() :: pos_integer()
  def default_push_interval, do: @default_push_interval_milliseconds

  @doc "Applies the environment overrides (non-empty variables) to git settings."
  @spec with_environment(t() | nil, %{String.t() => String.t()}) :: t() | nil
  def with_environment(nil, _environment), do: nil

  def with_environment(%__MODULE__{} = git, environment) do
    Enum.reduce(@environment_overrides, git, fn {key, variable}, git ->
      case Map.get(environment, variable) do
        value when is_binary(value) and value != "" -> Map.put(git, key, value)
        _absent -> git
      end
    end)
  end
end
