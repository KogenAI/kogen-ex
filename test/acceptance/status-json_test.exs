defmodule Kogen.Acceptance.StatusJSONTest do
  use Kogen.Testkit.Case

  alias Kogen.Testkit.Proc

  @moduletag :acceptance
  @project_root Path.expand("../..", __DIR__)

  @probe_intent """
  ---
  title: Status probe
  domains: [kernel]
  size: small
  ---
  Report the state of one draft Intent.

  ## Acceptance
  - A1: The status command reports the probe Intent as a draft.

  ## Verify
  - A1: test
  """

  @tag intent: "status-json/A1"
  test "prints JSON fields for a draft Intent", %{tmp_dir: tmp_dir} do
    repo = Kogen.Testkit.Git.create!(tmp_dir)
    install_probe(repo)
    commit_probe(repo)

    output =
      Proc.cmd!(
        "elixir",
        child_args() ++
          [
            "-e",
            ~s{Kogen.Kernel.CLI.main(["status", "--project", "#{repo}", "--json"])}
          ],
        cd: repo
      )

    assert output |> String.split("\n", trim: true) |> Enum.map(&:json.decode/1) == [
             %{
               "slug" => "status-probe",
               "status" => "draft",
               "build_id" => :null,
               "landed_sha" => :null
             }
           ]
  end

  defp install_probe(repo) do
    project_yaml = Path.join(repo, ".kogen/project.yaml")
    File.mkdir_p!(Path.dirname(project_yaml))
    File.cp!(Path.join(@project_root, ".kogen/project.yaml"), project_yaml)

    intent = Path.join([repo, ".kogen/intents/status-probe/intent.md"])
    File.mkdir_p!(Path.dirname(intent))
    File.write!(intent, @probe_intent)
  end

  defp commit_probe(repo) do
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
        "add status probe"
      ],
      cd: repo
    )
  end

  defp child_args do
    Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
  end
end
