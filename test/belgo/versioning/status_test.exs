defmodule Belgo.Versioning.StatusTest do
  use ExUnit.Case, async: true

  alias Belgo.Config.Git, as: GitConfig
  alias Belgo.Versioning.Git
  alias Belgo.Versioning.Status

  @moduletag :tmp_dir
  @author %{name: "Homer", email: "homer@springfield"}

  setup %{tmp_dir: tmp_dir} do
    directory = Path.join(tmp_dir, "inventory")
    remote = Path.join(tmp_dir, "remote.git")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "devices.yaml"), "homer-laptop: {}\n")
    {_output, 0} = System.cmd("git", ["init", "--quiet", "--bare", remote])
    %{directory: directory, git: %GitConfig{remote: remote, branch: "main"}}
  end

  test "disabled without git settings", %{directory: directory} do
    assert %Status{enabled?: false} = Status.read(directory, nil, [])
  end

  test "every file is a change before the repository exists", %{directory: directory, git: git} do
    assert %Status{enabled?: true, repository?: false, changes: ["devices.yaml"]} =
             Status.read(directory, git, [])
  end

  test "changes, then commits to push, then up to date", %{directory: directory, git: git} do
    {:ok, _output} = Git.init(directory)

    assert %Status{
             repository?: true,
             changes: ["devices.yaml"],
             last_commit: nil,
             to_push?: false
           } =
             Status.read(directory, git, [])

    commit(directory, "Initial inventory")

    # The branch does not exist on the remote yet.
    assert %Status{changes: [], to_push?: true, last_commit: %{subject: "Initial inventory"}} =
             Status.read(directory, git, [])

    {:ok, _output} = Git.push(directory, git.remote, git.branch)
    assert %Status{to_push?: false, ahead: 0} = Status.read(directory, git, [])

    File.write!(Path.join(directory, "networks.yaml"), "springfield: {}\n")
    assert %Status{changes: ["networks.yaml"], to_push?: false} = Status.read(directory, git, [])

    commit(directory, "Update networks.yaml")
    assert %Status{changes: [], to_push?: true, ahead: 1} = Status.read(directory, git, [])
  end

  test "without remote there is nothing to push", %{directory: directory, git: git} do
    {:ok, _output} = Git.init(directory)
    commit(directory, "Initial inventory")

    assert %Status{remote: nil, to_push?: false} =
             Status.read(directory, %{git | remote: nil}, [])
  end

  defp commit(directory, message) do
    {:ok, _paths} = Git.stage_all(directory)
    {:ok, _output} = Git.commit(directory, message, @author)
  end
end
