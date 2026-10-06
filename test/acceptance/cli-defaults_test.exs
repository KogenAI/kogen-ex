defmodule Kogen.Acceptance.CliDefaultsTest do
  use Kogen.Testkit.Case

  alias Kogen.Testkit.Proc

  @moduletag :acceptance
  @project_root Path.expand("../..", __DIR__)

  @probe_intent """
  ---
  title: Defaults probe
  domains: [kernel]
  size: small
  ---
  Report the state of one draft Intent.

  ## Acceptance
  - A1: The status command reports the probe Intent as a draft.

  ## Verify
  - A1: test
  """

  @tag intent: "cli-defaults/A1"
  test "version works without a project", %{tmp_dir: tmp_dir} do
    output = cli(["version"], tmp_dir)
    assert output =~ ~r/^kogen /m
  end

  @tag intent: "cli-defaults/A2"
  test "help works without a project", %{tmp_dir: tmp_dir} do
    output = cli(["help"], tmp_dir)
    assert output =~ ~r/^Commands:/
    assert output =~ ~r/^  status/m
    refute output =~ "--project <checkout>\n\nUsage"
    refute output =~ "requires --project"
    refute output =~ "Usage:"
  end

  @tag intent: "cli-defaults/A3"
  test "status defaults to the current directory", %{tmp_dir: tmp_dir} do
    repo = Kogen.Testkit.Git.create!(tmp_dir)
    project_yaml = Path.join(repo, ".kogen/project.yaml")
    File.mkdir_p!(Path.dirname(project_yaml))
    File.cp!(Path.join(@project_root, ".kogen/project.yaml"), project_yaml)
    intent = Path.join(repo, ".kogen/intents/defaults-probe/intent.md")
    File.mkdir_p!(Path.dirname(intent))
    File.write!(intent, @probe_intent)
    commit(repo)

    output = cli(["status", "--json"], repo)

    assert output |> String.split("\n", trim: true) |> Enum.map(&:json.decode/1) == [
             %{
               "slug" => "defaults-probe",
               "status" => "draft",
               "build_id" => :null,
               "landed_sha" => :null,
               "priority" => 0,
               "blocks_on" => [],
               "detail" => :null
             }
           ]
  end

  defp cli(args, cd) do
    Proc.cmd!("elixir", child_args() ++ ["-e", "Kogen.Kernel.CLI.main(#{inspect(args)})"], cd: cd)
  end

  defp commit(repo) do
    Proc.cmd!("git", ["add", "--all"], cd: repo)

    Proc.cmd!(
      "git",
      [
        "-c",
        "user.name=Kogen Test",
        "-c",
        "user.email=test@kogen.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--quiet",
        "-m",
        "add defaults probe"
      ],
      cd: repo
    )
  end

  defp child_args do
    Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
  end
end
