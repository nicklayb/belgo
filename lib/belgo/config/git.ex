defmodule Belgo.Config.Git do
  @moduledoc """
  Versioning of the data directory with git (durations in milliseconds).

  Present when `config.yaml` has a `git` key: the directory becomes a repository and
  changes are committed once the files are left alone for `commit_delay`. With a
  `remote`, commits are pushed every `push_interval` (never pulled, never forced).
  `branch` is the remote branch, the current local branch when `nil`.
  """

  @default_commit_delay_milliseconds 5 * 60_000
  @default_push_interval_milliseconds 60 * 60_000
  @default_author_name "Belgo"
  @default_author_email "belgo@localhost"

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
end
