defmodule Belgo.Versioning.ServerTest do
  use ExUnit.Case, async: true

  alias Belgo.Versioning.Git
  alias Belgo.Versioning.Server

  @moduletag :tmp_dir
  @push_wait_milliseconds 500

  setup %{tmp_dir: tmp_dir} do
    directory = Path.join(tmp_dir, "inventory")
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "devices.yaml"), "homer-laptop: {}\n")
    %{directory: directory, tmp_dir: tmp_dir}
  end

  test "does nothing without git in config.yaml", %{directory: directory} do
    write_config(directory, "")
    server = start_server(directory)

    send(server, {:inventory_changed, nil})
    Server.flush(server)

    refute Git.repository?(directory)
  end

  test "creates the repository and commits the files at boot", %{directory: directory} do
    write_config(directory, "git:\n  commit_delay: 1h\n")
    start_server(directory)

    assert Git.repository?(directory)
    assert ["Initial inventory"] == log(directory)
  end

  test "commits once the changes are left alone", %{directory: directory} do
    write_config(directory, "git:\n  commit_delay: 1h\n")
    server = start_server(directory)

    File.write!(Path.join(directory, "devices.yaml"), "homer-laptop: {}\nbart-tablet: {}\n")
    send(server, {:inventory_changed, nil})
    File.write!(Path.join(directory, "networks.yaml"), "springfield: {}\n")
    send(server, {:inventory_changed, nil})

    assert ["Initial inventory"] == log(directory)

    Server.flush(server)
    assert ["Update devices.yaml, networks.yaml", "Initial inventory"] == log(directory)
  end

  test "the delay commits by itself", %{directory: directory} do
    write_config(directory, "git:\n  commit_delay: 0s\n")
    server = start_server(directory)

    File.write!(Path.join(directory, "networks.yaml"), "springfield: {}\n")
    send(server, {:inventory_changed, nil})

    assert eventually(fn -> ["Update networks.yaml", "Initial inventory"] == log(directory) end)
  end

  test "keeps an existing repository and pushes to the remote", %{
    directory: directory,
    tmp_dir: tmp_dir
  } do
    remote = Path.join(tmp_dir, "remote.git")
    {_output, 0} = System.cmd("git", ["init", "--quiet", "--bare", remote])
    {:ok, _output} = Git.init(directory)

    write_config(
      directory,
      "git:\n  commit_delay: 1h\n  remote: #{remote}\n  branch: springfield\n"
    )

    server = start_server(directory)

    Server.push(server)
    {:ok, head} = Git.head(directory)

    assert eventually(fn -> remote_head(remote, "springfield") == head end)
  end

  test "never forces a push over a remote that moved on", %{
    directory: directory,
    tmp_dir: tmp_dir
  } do
    remote = Path.join(tmp_dir, "remote.git")
    clone = Path.join(tmp_dir, "clone")
    {_output, 0} = System.cmd("git", ["init", "--quiet", "--bare", remote])
    {_output, 0} = System.cmd("git", ["clone", "--quiet", remote, clone], stderr_to_stdout: true)
    File.write!(Path.join(clone, "flanders.yaml"), "okily: dokily\n")

    {_output, 0} =
      System.cmd(
        "git",
        [
          "-C",
          clone,
          "-c",
          "user.name=Ned",
          "-c",
          "user.email=ned@springfield",
          "-c",
          "commit.gpgsign=false",
          "commit",
          "--quiet",
          "--allow-empty",
          "--message",
          "Hi-diddly-ho"
        ]
      )

    {_output, 0} =
      System.cmd("git", ["-C", clone, "push", "--quiet", "origin", "HEAD:refs/heads/main"],
        stderr_to_stdout: true
      )

    remote_before = remote_head(remote, "main")
    write_config(directory, "git:\n  commit_delay: 1h\n  remote: #{remote}\n  branch: main\n")
    server = start_server(directory)

    ExUnit.CaptureLog.capture_log(fn ->
      Server.push(server)
      Process.sleep(@push_wait_milliseconds)
      :sys.get_state(server)
    end)

    assert remote_before == remote_head(remote, "main")
    assert Process.alive?(server)
  end

  test "commits now on demand and broadcasts commits and pushes", %{
    directory: directory,
    tmp_dir: tmp_dir
  } do
    remote = Path.join(tmp_dir, "remote.git")
    {_output, 0} = System.cmd("git", ["init", "--quiet", "--bare", remote])
    write_config(directory, "git:\n  commit_delay: 1h\n  remote: #{remote}\n  branch: main\n")
    pubsub = Belgo.Versioning.ServerTest.PubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    Phoenix.PubSub.subscribe(pubsub, Server.topic())
    server = start_server(directory, pubsub: pubsub)
    assert_receive {:versioning_committed, {:ok, ["config.yaml", "devices.yaml"]}}

    # No timer pending: the hand edit is committed anyway.
    File.write!(Path.join(directory, "devices.yaml"), "homer-laptop: {}\nlisa-laptop: {}\n")
    assert {:ok, ["devices.yaml"]} == Server.commit_now(server)
    assert {:ok, []} == Server.commit_now(server)
    assert ["Update devices.yaml", "Initial inventory"] == log(directory)

    Server.push(server)
    assert_receive {:versioning_pushed, {:ok, _sha}}, 5_000
    assert %{pushing?: false, directory: ^directory} = Server.info(server)
  end

  test "commits the pending changes when stopping", %{directory: directory} do
    write_config(directory, "git:\n  commit_delay: 1h\n")
    server = start_server(directory)

    File.write!(Path.join(directory, "locations.yaml"), "evergreen-terrace: {}\n")
    send(server, {:inventory_changed, nil})
    GenServer.stop(server)

    assert ["Update locations.yaml", "Initial inventory"] == log(directory)
  end

  defp start_server(directory, options \\ []) do
    start_supervised!({Task.Supervisor, name: task_supervisor(directory)})

    server =
      start_supervised!(
        {Server,
         [directory: directory, name: nil, task_supervisor: task_supervisor(directory)] ++
           options},
        restart: :temporary
      )

    # Waits for the boot commit.
    :sys.get_state(server)
    server
  end

  defp task_supervisor(directory), do: {:global, {__MODULE__, directory}}

  defp write_config(directory, git) do
    File.write!(Path.join(directory, "config.yaml"), "version: 1\n" <> git)
  end

  defp log(directory) do
    {output, 0} = System.cmd("git", ["-C", directory, "log", "--format=%s"])
    String.split(output, "\n", trim: true)
  end

  defp remote_head(remote, branch) do
    case System.cmd("git", ["-C", remote, "rev-parse", "--verify", "--quiet", branch]) do
      {output, 0} -> String.trim(output)
      _missing -> nil
    end
  end

  @attempts 250
  @attempt_delay_milliseconds 20

  defp eventually(check, attempts \\ @attempts)
  defp eventually(check, 0), do: check.()

  defp eventually(check, attempts) do
    check.() or
      (Process.sleep(@attempt_delay_milliseconds) && eventually(check, attempts - 1))
  end
end
