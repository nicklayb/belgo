defmodule Belgo.Versioning.Status do
  @moduledoc """
  Where the data directory stands with git, for the settings page: uncommitted
  changes, the last commit and whether `HEAD` is on the remote. Reading it runs git
  commands (the remote is read with `ls-remote`: nothing is fetched nor pulled) and
  never changes the repository.
  """

  alias Belgo.Config.Git, as: GitConfig
  alias Belgo.Versioning
  alias Belgo.Versioning.Git

  defstruct enabled?: false,
            repository?: false,
            changes: [],
            last_commit: nil,
            remote: nil,
            branch: nil,
            remote_head: nil,
            to_push?: false,
            ahead: nil,
            error: nil

  @type t :: %__MODULE__{
          enabled?: boolean(),
          repository?: boolean(),
          changes: [String.t()],
          last_commit: %{sha: String.t(), subject: String.t(), date: String.t()} | nil,
          remote: String.t() | nil,
          branch: String.t() | nil,
          remote_head: String.t() | nil,
          to_push?: boolean(),
          ahead: non_neg_integer() | nil,
          error: String.t() | nil
        }

  @doc """
  Reads the status of `directory` with its git settings (`nil`: versioning disabled).
  `environment` carries the HTTPS credentials (`Belgo.Versioning.credentials_environment/1`).
  """
  @spec read(Path.t(), GitConfig.t() | nil, [{String.t(), String.t()}]) :: t()
  def read(_directory, nil, _environment), do: %__MODULE__{}

  def read(directory, %GitConfig{} = git, environment) do
    if Git.repository?(directory) do
      read_repository(directory, git, environment)
    else
      # Created on the first commit, with every file.
      %__MODULE__{enabled?: true, changes: data_files(directory), remote: git.remote}
    end
  end

  @doc """
  Reads the status of the data directory with its current `config.yaml` (an invalid
  one disables versioning) and the HTTPS credentials of the environment.
  """
  @spec current(Path.t()) :: t()
  def current(directory) do
    git =
      case Belgo.Config.load(directory) do
        {:ok, config} -> config.git
        {:error, _messages} -> nil
      end

    environment =
      case Versioning.credentials_environment() do
        {:ok, environment} -> environment
        {:error, _message} -> []
      end

    read(directory, git, environment)
  end

  @doc "Commit message summary of a status, `nil` without commit."
  @spec commit_summary(t()) :: String.t() | nil
  def commit_summary(%__MODULE__{last_commit: nil}), do: nil
  def commit_summary(%__MODULE__{last_commit: commit}), do: "#{commit.sha} #{commit.subject}"

  defp read_repository(directory, git, environment) do
    with {:ok, changes} <- Git.changed_paths(directory),
         {:ok, current_branch} <- Git.current_branch(directory) do
      last_commit =
        case Git.last_commit(directory) do
          {:ok, commit} -> commit
          {:error, _no_commit} -> nil
        end

      status = %__MODULE__{
        enabled?: true,
        repository?: true,
        changes: changes,
        last_commit: last_commit,
        remote: git.remote,
        branch: git.branch || current_branch
      }

      put_remote(status, directory, environment)
    else
      {:error, reason} ->
        %__MODULE__{enabled?: true, repository?: true, error: Versioning.format_error(reason)}
    end
  end

  defp put_remote(%__MODULE__{remote: nil} = status, _directory, _environment), do: status
  defp put_remote(%__MODULE__{last_commit: nil} = status, _directory, _environment), do: status
  defp put_remote(%__MODULE__{branch: nil} = status, _directory, _environment), do: status

  defp put_remote(status, directory, environment) do
    case Git.remote_head(directory, status.remote, status.branch, environment) do
      {:ok, nil} ->
        %{status | to_push?: true}

      {:ok, remote_head} ->
        %{
          status
          | remote_head: remote_head,
            to_push?: not Git.ancestor?(directory, "HEAD", remote_head),
            ahead: Git.commits_ahead(directory, remote_head)
        }

      # Unknown: pushing stays possible, it tells what goes wrong.
      {:error, reason} ->
        %{status | to_push?: true, error: Versioning.format_error(reason)}
    end
  end

  defp data_files(directory) do
    directory
    |> File.ls!()
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.sort()
  end
end
