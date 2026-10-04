defmodule Kogen.Kernel.CLITest do
  use Kogen.Testkit.Case

  alias Kogen.Kernel.CLI
  alias Kogen.Kernel.CLI.Arguments

  @fixture Path.expand("../../fixtures/hello_app", __DIR__)

  test "version works with or without a project path" do
    assert {0, "kogen 0.0.0\n"} = CLI.execute(["version"])
    assert {0, "kogen 0.0.0\n"} = CLI.execute(["version", "--project", @fixture])
  end

  test "project commands default to the current directory" do
    assert {:ok, args} = Arguments.parse(["status"])
    assert Path.type(args.project) == :absolute
    assert args.origin == args.project
  end

  test "build accepts only the built-in recipes and defaults to staged" do
    assert {:ok, default} = Arguments.parse(["build", "greet"])
    assert default.recipe == "staged"

    assert {:ok, direct} = Arguments.parse(["build", "greet", "--recipe", "direct"])
    assert direct.recipe == "direct"

    assert {:ok, direct_shell} =
             Arguments.parse(["build", "greet", "--recipe", "direct-shell"])

    assert direct_shell.recipe == "direct-shell"

    assert {:error, "--recipe must be staged, direct, or direct-shell"} =
             Arguments.parse(["build", "greet", "--recipe", "unknown"])
  end

  test "provider commands parse account labels without requiring a project" do
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
    assert list.origin == nil
  end

  test "intent check parses and lints from the named project root" do
    assert {0, output} =
             CLI.execute([
               "intent",
               "check",
               ".kogen/intents/greet/intent.md",
               "--project",
               @fixture
             ])

    assert output =~ "intent greet: valid"
    assert output =~ "sha256"
  end

  test "intent check prints parse issues and uses exit code 2", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "broken.md"), "not an Intent\n")

    assert {2, output} =
             CLI.execute(["intent", "check", "broken.md", "--project", tmp_dir])

    assert output =~ "parse failed"
    assert output =~ "frontmatter must start"
  end

  test "status emits text and derives draft from the selected project branch", %{
    tmp_dir: tmp_dir
  } do
    project = Kogen.Testkit.Git.create!(tmp_dir)
    Kogen.Testkit.Proc.cmd!("git", ["-C", project, "branch", "-M", "main"], env: git_env())
    intent_path = Path.join([project, ".kogen", "intents", "greet", "intent.md"])
    File.mkdir_p!(Path.dirname(intent_path))
    File.write!(intent_path, "draft Intent\n")

    assert {0, "greet draft run=- landed=-\n"} =
             CLI.execute(["status", "--project", project, "--base", "main"])

    assert {0, output} =
             CLI.execute(["status", "--project", project, "--base", "main", "--json"])

    assert :json.decode(output) == [
             %{
               "slug" => "greet",
               "status" => "draft",
               "run_id" => :null,
               "landed_sha" => :null
             }
           ]
  end

  test "report requires JSON output" do
    assert {2, output} = CLI.execute(["report", "greet", "--project", @fixture])
    assert output =~ "report requires --json"
  end

  defp git_env do
    [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_AUTHOR_NAME", "Kogen Test"},
      {"GIT_AUTHOR_EMAIL", "test@kogen.invalid"},
      {"GIT_COMMITTER_NAME", "Kogen Test"},
      {"GIT_COMMITTER_EMAIL", "test@kogen.invalid"}
    ]
  end
end
