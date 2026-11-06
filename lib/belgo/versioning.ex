defmodule Belgo.Versioning do
  @moduledoc """
  Versioning of the data directory with git (`git` in `config.yaml`): pure helpers
  of `Belgo.Versioning.Server`, which commits and pushes.

  Credentials never live in the data files: SSH remotes use the usual SSH setup
  (`GIT_SSH_COMMAND`, keys), HTTPS remotes the `BELGO_GIT_TOKEN` secret (with
  `BELGO_GIT_USERNAME`, `x-access-token` by default), sent as a basic authorization
  header through git's environment configuration, so it never shows in a command line.
  """

  alias Belgo.Providers.Secrets

  @initial_message "Initial inventory"
  @token_secret "BELGO_GIT_TOKEN"
  @username_secret "BELGO_GIT_USERNAME"
  @default_username "x-access-token"
  @maximum_listed_paths 5

  @doc "Message of a commit of the given paths (the first commit is the initial inventory)."
  @spec commit_message([String.t()], boolean()) :: String.t()
  def commit_message(_paths, true = _initial?), do: @initial_message

  def commit_message(paths, false = _initial?) when length(paths) > @maximum_listed_paths,
    do: "Update #{length(paths)} files\n\n" <> Enum.join(paths, "\n")

  def commit_message(paths, false = _initial?), do: "Update " <> Enum.join(paths, ", ")

  @doc """
  Git environment variables carrying the HTTPS credentials, none without token; an
  error when the token file cannot be read.
  """
  @spec credentials_environment(Secrets.environment()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
  def credentials_environment(environment \\ System.get_env()) do
    if token_configured?(environment) do
      with {:ok, token} <- Secrets.fetch(@token_secret, environment),
           {:ok, username} <- username(environment) do
        {:ok,
         [
           {"GIT_CONFIG_COUNT", "1"},
           {"GIT_CONFIG_KEY_0", "http.extraHeader"},
           {"GIT_CONFIG_VALUE_0",
            "Authorization: Basic " <> Base.encode64("#{username}:#{token}")}
         ]}
      end
    else
      {:ok, []}
    end
  end

  defp token_configured?(environment),
    do: Enum.any?([@token_secret, @token_secret <> "_FILE"], &Map.has_key?(environment, &1))

  defp username(environment) do
    if Enum.any?([@username_secret, @username_secret <> "_FILE"], &Map.has_key?(environment, &1)),
      do: Secrets.fetch(@username_secret, environment),
      else: {:ok, @default_username}
  end
end
