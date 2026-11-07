defmodule Belgo.Versioning.Git do
  @moduledoc """
  Runs the `git` executable (`BELGO_GIT_PATH`, `git` from `PATH` by default) in the
  data directory. Every command trusts that directory (`safe.directory`: in a
  container the volume often belongs to another user) and never prompts.
  """

  @initial_branch "main"
  @success_exit_status 0

  @type result :: {:ok, String.t()} | {:error, {:git, non_neg_integer() | atom(), String.t()}}
  @type author :: %{name: String.t(), email: String.t()}

  @doc "Whether the directory itself is a repository (a parent repository does not count)."
  @spec repository?(Path.t()) :: boolean()
  def repository?(directory), do: File.exists?(Path.join(directory, ".git"))

  @doc "Creates a repository in the directory."
  @spec init(Path.t()) :: result()
  def init(directory),
    do: run(directory, ["init", "--quiet", "--initial-branch=#{@initial_branch}"])

  @doc "Stages every change of the directory and returns the staged paths."
  @spec stage_all(Path.t()) :: {:ok, [String.t()]} | result()
  def stage_all(directory) do
    with {:ok, _output} <- run(directory, ["add", "--all"]),
         {:ok, output} <- run(directory, ["diff", "--cached", "--name-only", "-z"]) do
      {:ok, String.split(output, <<0>>, trim: true)}
    end
  end

  @doc "Whether the repository has a commit yet."
  @spec committed?(Path.t()) :: boolean()
  def committed?(directory), do: match?({:ok, _sha}, head(directory))

  @doc "Returns the commit of `HEAD`."
  @spec head(Path.t()) :: result()
  def head(directory) do
    with {:ok, output} <- run(directory, ["rev-parse", "--verify", "--quiet", "HEAD"]),
         do: {:ok, String.trim(output)}
  end

  @doc "Commits the staged changes as the given author (also the committer), unsigned."
  @spec commit(Path.t(), String.t(), author()) :: result()
  def commit(directory, message, author) do
    run(
      directory,
      ["-c", "user.name=#{author.name}", "-c", "user.email=#{author.email}"] ++
        ["-c", "commit.gpgsign=false"] ++
        ["commit", "--quiet", "--message", message]
    )
  end

  @doc """
  Paths with uncommitted changes (modified, added, deleted or untracked), without
  staging anything.
  """
  @spec changed_paths(Path.t()) :: {:ok, [String.t()]} | result()
  def changed_paths(directory) do
    with {:ok, output} <-
           run(directory, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]) do
      {:ok, parse_status(output)}
    end
  end

  @doc "The branch `HEAD` is on, `nil` when detached."
  @spec current_branch(Path.t()) :: {:ok, String.t() | nil} | result()
  def current_branch(directory) do
    case run(directory, ["symbolic-ref", "--quiet", "--short", "HEAD"]) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, {:git, _status, _output}} -> {:ok, nil}
    end
  end

  @doc "Short hash, subject and relative date of the last commit."
  @spec last_commit(Path.t()) ::
          {:ok, %{sha: String.t(), subject: String.t(), date: String.t()}} | result()
  def last_commit(directory) do
    with {:ok, output} <- run(directory, ["log", "-1", "--format=%h%x00%s%x00%cI"]) do
      [sha, subject, date] =
        output
        |> String.trim_trailing()
        |> String.split(<<0>>)

      {:ok, %{sha: sha, subject: subject, date: date}}
    end
  end

  @doc """
  The commit of `branch` on the remote (read with `ls-remote`, nothing is fetched),
  `nil` when the branch does not exist there.
  """
  @spec remote_head(Path.t(), String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t() | nil} | result()
  def remote_head(directory, remote, branch, environment \\ []) do
    with {:ok, output} <-
           run(directory, ["ls-remote", "--heads", remote, "refs/heads/#{branch}"], environment) do
      case String.split(output) do
        [sha | _reference] -> {:ok, sha}
        [] -> {:ok, nil}
      end
    end
  end

  @doc """
  Whether `ancestor` is an ancestor of (or equal to) `descendant`; `false` as well
  when one of them is unknown locally.
  """
  @spec ancestor?(Path.t(), String.t(), String.t()) :: boolean()
  def ancestor?(directory, ancestor, descendant),
    do:
      match?(
        {:ok, _output},
        run(directory, ["merge-base", "--is-ancestor", ancestor, descendant])
      )

  @doc "Number of commits of `HEAD` missing from `base` (known locally), else `nil`."
  @spec commits_ahead(Path.t(), String.t()) :: non_neg_integer() | nil
  def commits_ahead(directory, base) do
    with {:ok, output} <- run(directory, ["rev-list", "--count", "#{base}..HEAD"]),
         {count, _rest} <- Integer.parse(output) do
      count
    else
      _unknown -> nil
    end
  end

  @doc """
  Pushes `HEAD` to the remote (a URL or a configured remote name), on `branch` or the
  branch of the same name. Never forced: a remote that moved on is an error.
  """
  @spec push(Path.t(), String.t(), String.t() | nil, [{String.t(), String.t()}]) :: result()
  def push(directory, remote, branch, environment \\ []) do
    run(directory, ["push", "--quiet", remote, refspec(branch)], environment)
  end

  # Entries are "XY path", a rename or copy being followed by its source path.
  defp parse_status(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> Enum.reduce({[], false}, fn
      _source, {paths, true} ->
        {paths, false}

      <<status::binary-size(2), " ", path::binary>>, {paths, _skip} ->
        {[path | paths], String.first(status) in ["R", "C"]}

      _other, accumulator ->
        accumulator
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp refspec(nil), do: "HEAD"
  defp refspec(branch), do: "HEAD:refs/heads/#{branch}"

  defp run(directory, arguments, environment \\ []) do
    case System.cmd(
           executable(),
           ["-C", directory, "-c", "safe.directory=#{directory}"] ++ arguments,
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"} | environment]
         ) do
      {output, @success_exit_status} -> {:ok, output}
      {output, status} -> {:error, {:git, status, String.trim(output)}}
    end
  rescue
    error in ErlangError -> {:error, {:git, :unavailable, Exception.message(error)}}
  end

  defp executable, do: System.get_env("BELGO_GIT_PATH", "git")
end
