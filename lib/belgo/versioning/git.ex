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
  Pushes `HEAD` to the remote (a URL or a configured remote name), on `branch` or the
  branch of the same name. Never forced: a remote that moved on is an error.
  """
  @spec push(Path.t(), String.t(), String.t() | nil, [{String.t(), String.t()}]) :: result()
  def push(directory, remote, branch, environment \\ []) do
    run(directory, ["push", "--quiet", remote, refspec(branch)], environment)
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
