defmodule Kogen.Kernel.CLITest do
  use Kogen.Testkit.Case

  alias Kogen.Kernel.CLI
  alias Kogen.Kernel.CLI.Arguments
  alias Kogen.Testkit.Git

  @fixture Path.expand("../../fixtures/hello_app", __DIR__)

  test "version works without a project path" do
    assert {0, "kogen 0.0.0\n"} = CLI.execute(["version"])
  end

  test "top-level help is the compact golden command list" do
    assert CLI.execute([]) == {0, top_level_help()}
    assert CLI.execute(["help"]) == {0, top_level_help()}
    assert CLI.execute(["--help"]) == {0, top_level_help()}
  end

  test "command help is a golden subcommand and option list" do
    assert CLI.execute(["intent", "--help"]) == {0, intent_help()}
    assert CLI.execute(["help", "intent"]) == {0, intent_help()}
    assert ["build", "--help"] |> CLI.execute() |> elem(1) =~ "build show <slug>"
  end

  test "project commands default to cwd and defer base selection" do
    assert {:ok, args} = Arguments.parse(["status"])
    assert Path.type(args.project) == :absolute
    assert args.origin == nil
    assert args.base == nil

    assert {:ok, explicit} = Arguments.parse(["status", "--origin", "/tmp/kogen-origin"])
    assert explicit.origin == "/tmp/kogen-origin"
  end

  test "build settings are no longer command flags" do
    assert {:ok, build} = Arguments.parse(["build", "greet"])
    assert build.command == :build

    assert {:ok, show} = Arguments.parse(["build", "show", "greet"])
    assert show.command == :build_show
  end

  test "provider commands keep account labels on login and logout" do
    assert {:ok, login} = Arguments.parse(["provider", "login", "chatgpt", "--as", "personal"])
    assert login.command == :provider_login
    assert login.account_label == "personal"
    assert login.project == nil
    assert login.origin == nil

    assert {:ok, logout} = Arguments.parse(["provider", "logout", "chatgpt", "--as", "personal"])
    assert logout.command == :provider_logout
    assert logout.account_label == "personal"

    assert {:ok, list} = Arguments.parse(["provider", "list"])
    assert list.command == :provider_list
    assert list.project == nil
  end

  test "old command and flag forms return moved errors" do
    cases = [
      {["approve", "greet"], "moved: use kogen intent approve <slug>"},
      {["report", "greet"], "moved: use kogen build show <slug>"},
      {["build", "greet", "--model", "m"], "moved: set build.roles.builder.model"},
      {["build", "greet", "--effort", "high"], "moved: set build.roles.builder.effort"},
      {["build", "greet", "--recipe", "direct"], "moved: set build.recipe"},
      {["build", "greet", "--borrow", "codex"], "moved: use kogen provider login chatgpt"},
      {["build", "greet", "--as", "personal"], "moved: set account"}
    ]

    for {argv, message} <- cases do
      assert {2, output} = CLI.execute(argv)
      assert output =~ message
    end
  end

  test "intent check resolves a project-relative path or slug" do
    assert {0, path_output} =
             CLI.execute([
               "intent",
               "check",
               ".kogen/intents/greet/intent.md",
               "--project",
               @fixture
             ])

    assert path_output =~ "intent greet: valid"
    assert path_output =~ "sha256"

    assert {0, slug_output} =
             CLI.execute(["intent", "check", "greet", "--project", @fixture])

    assert slug_output =~ "intent greet: valid"
  end

  test "intent check prints parse issues and uses exit code 2", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "broken.md"), "not an Intent\n")

    assert {2, output} = CLI.execute(["intent", "check", "broken.md", "--project", tmp_dir])
    assert output =~ "parse failed"
    assert output =~ "frontmatter must start"
  end

  test "status emits text and JSON for the selected project branch", %{tmp_dir: tmp_dir} do
    project = Git.create!(tmp_dir)
    write_project_config(project)
    Git.git!(project, ["branch", "-M", "main"])
    intent_path = Path.join([project, ".kogen", "intents", "greet", "intent.md"])
    File.mkdir_p!(Path.dirname(intent_path))
    File.write!(intent_path, "draft Intent\n")

    assert {0, "greet draft run=- landed=-\n"} =
             CLI.execute(["status", "--project", project, "--base", "main"])

    assert {0, output} = CLI.execute(["status", "--project", project, "--base", "main", "--json"])

    assert :json.decode(output) == [
             %{
               "slug" => "greet",
               "status" => "draft",
               "run_id" => :null,
               "landed_sha" => :null
             }
           ]
  end

  defp write_project_config(project) do
    File.mkdir_p!(Path.join(project, ".kogen"))

    File.cp!(
      Path.join(@fixture, ".kogen/project.yaml"),
      Path.join(project, ".kogen/project.yaml")
    )
  end

  defp top_level_help do
    """
    Commands:
      status      Show project and Intent state
      intent      Check, shape, or approve an Intent
      build       Build an Intent or show a Build report
      reconcile   Reconcile a Build after a crash
      provider    Manage Kogen ChatGPT logins
      version     Show the Kogen version
      help        Show help for a command
    """
  end

  defp intent_help do
    """
    Usage: kogen intent <command> [arguments] [options]

    Commands:
      check <slug|path>     Parse and lint an Intent
      shape <slug>          Create an Intent from --task-file
      approve <slug>        Review and record an Intent approval

    Options:
      --project <checkout>  Project checkout (default: current directory)
      --origin <repo>       Local Git repository used for state and landing
      --base <branch>       Target branch (project setting, origin HEAD, then current branch)
    """
  end
end
