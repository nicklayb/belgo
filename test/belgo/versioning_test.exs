defmodule Belgo.VersioningTest do
  use ExUnit.Case, async: true

  alias Belgo.Versioning

  test "the first commit is the initial inventory" do
    assert "Initial inventory" == Versioning.commit_message(["devices.yaml"], true)
  end

  test "commits name the changed files, a count when there are many" do
    assert "Update devices.yaml, networks.yaml" ==
             Versioning.commit_message(["devices.yaml", "networks.yaml"], false)

    paths = Enum.map(1..6, &"springfield-#{&1}.yaml")
    message = Versioning.commit_message(paths, false)
    assert message =~ ~r/\AUpdate 6 files\n\n/
    assert message =~ "springfield-6.yaml"
  end

  test "no credentials without token" do
    assert {:ok, []} == Versioning.credentials_environment(%{})
  end

  test "the token becomes a basic authorization header" do
    assert {:ok, environment} =
             Versioning.credentials_environment(%{
               "BELGO_GIT_TOKEN" => "donut",
               "BELGO_GIT_USERNAME" => "homer"
             })

    assert {"GIT_CONFIG_VALUE_0", "Authorization: Basic " <> Base.encode64("homer:donut")} in environment

    assert {:ok, default_environment} =
             Versioning.credentials_environment(%{"BELGO_GIT_TOKEN" => "donut"})

    assert {"GIT_CONFIG_VALUE_0",
            "Authorization: Basic " <> Base.encode64("x-access-token:donut")} in default_environment
  end

  test "an unreadable token file is an error" do
    assert {:error, message} =
             Versioning.credentials_environment(%{"BELGO_GIT_TOKEN_FILE" => "/nonexistent/token"})

    assert message =~ "BELGO_GIT_TOKEN_FILE"
  end
end
