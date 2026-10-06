defmodule Kogen.Kernel.CLITest do
  use Kogen.Testkit.Case

  import ExUnit.CaptureIO

  alias Kogen.Cli.Arguments
  alias Kogen.Cli.Version
  alias Kogen.Kernel.CLI
  alias Kogen.Testkit.Git

  @fixture Path.expand("../../fixtures/hello_app", __DIR__)
  @golden Path.expand("../fixtures/cli", __DIR__)

  @topics [
    [],
    ["status"],
    ["intent"],
    ["intent", "shape"],
    ["intent", "approve"],
    ["intent", "remove"],
    ["queue"],
    ["queue", "start"],
    ["queue", "stop"],
    ["provider"],
    ["provider", "list"],
    ["provider", "login"],
    ["provider", "logout"],
    ["provider", "use"],
    ["version"]
  ]

  test "usage errors show each command's documented help" do
    for topic <- @topics do
      assert {2, output} = CLI.execute(topic ++ ["--bogus"])
      assert String.ends_with?(output, "\n\n" <> golden(topic)), inspect(topic)
    end

    assert CLI.execute([]) == {0, golden([])}
    assert CLI.execute(["help"]) == {0, golden([])}
    assert CLI.execute(["intent"]) == {0, golden(["intent"])}
    assert CLI.execute(["queue"]) == {0, golden(["queue"])}
    assert CLI.execute(["provider"]) == {0, golden(["provider"])}
  end

  test "commands and flags outside the fixed CLI return usage errors" do
    for argv <- [
          ["checks"],
          ["checks", "sample", "proposal.json", "sample.json"],
          ["checks", "effect", "qualification.json", "before", "checked"],
          ["help", "checks"],
          ["help", "status"],
          ["--help"],
          ["status", "--help"],
          ["intent", "shape", "greet", "-", "--json"],
          ["provider", "login", "chatgpt", "--as", "work"],
          ["provider", "logout", "chatgpt", "--as", "work"],
          ["provider", "use", "chatgpt"],
          ["provider", "use", "chatgpt", "--as", ""]
        ] do
      assert {2, _output} = CLI.execute(argv), inspect(argv)
    end

    {0, help} = CLI.execute(["help"])
    refute help =~ "checks"
  end

  test "the top level lists commands first and nothing else" do
    {0, help} = CLI.execute([])
    assert String.starts_with?(help, "Commands:\n  status ")
    refute help =~ "--"
  end

  test "errors name the problem and show only the meant command's help" do
    cases = [
      {["foo"], "kogen: unknown command 'foo'", []},
      {["intent", "check2"], "kogen intent: unknown command 'check2'", ["intent"]},
      {["intent", "approve"], "kogen intent approve: missing <slug>", ["intent", "approve"]},
      {["intent", "shape", "x"], "kogen intent shape: missing <file|->", ["intent", "shape"]},
      {["intent", "remove", "--force"], "kogen intent remove: missing <slug>",
       ["intent", "remove"]},
      {["status", "--bogus"], "kogen status: unknown option '--bogus'", ["status"]},
      {["status", "a", "b"], "kogen status: unexpected argument 'b'", ["status"]},
      {["status", "--watch", "--json"], "kogen status: --watch and --json can't be combined",
       ["status"]},
      {["status", "--base"], "kogen status: --base needs a value", ["status"]},
      {["queue", "start", "now"], "kogen queue start: unexpected argument 'now'",
       ["queue", "start"]},
      {["provider", "login", "grok"],
       "kogen provider login: unknown provider 'grok' (supported: chatgpt)",
       ["provider", "login"]},
      {["intent", "approve", "greet", "XYZ"],
       "kogen intent approve: <hash> must be 6 to 64 lowercase hex characters",
       ["intent", "approve"]},
      {["help", "nope"], "kogen help: unexpected argument 'nope'", []}
    ]

    for {argv, message, topic} <- cases do
      assert CLI.execute(argv) == {2, message <> "\n\n" <> golden(topic)}, inspect(argv)
    end
  end

  test "old forms exit 2 with one moved line" do
    cases = [
      {["build", "greet"], "kogen queue start (approved Intents build from the queue)"},
      {["build", "show", "greet"], "kogen status <slug>"},
      {["report", "greet"], "kogen status <slug>"},
      {["approve", "greet"], "kogen intent approve <slug> <hash>"},
      {["reconcile", "abc"],
       "kogen status (crash recovery is automatic in status and queue start)"},
      {["reconcile"], "kogen status (crash recovery is automatic in status and queue start)"},
      {["intent", "check", "greet"],
       "kogen intent approve <slug> (prints the review card and check results)"},
      {["intent", "close", "greet"], "kogen intent remove <slug>"},
      {["--version"], "kogen version"},
      {["intent", "shape", "x", "--task-file", "t.md"], "kogen intent shape <slug> <file>"},
      {["intent", "approve", "x", "--yes"], "kogen intent approve <slug> <hash>"},
      {["status", "--model", "m"], "build.roles.builder.model in .kogen/project.yaml"},
      {["status", "--effort", "max"], "build.roles.builder.effort in .kogen/project.yaml"},
      {["status", "--recipe", "direct"], "build.recipe in .kogen/project.yaml"},
      {["status", "--borrow", "codex"], "kogen provider login chatgpt for a Kogen-owned login"},
      {["queue", "start", "--as", "work"],
       "kogen provider use chatgpt --as <label> --project <checkout>"}
    ]

    for {argv, message} <- cases do
      assert CLI.execute(argv) == {2, "kogen: moved: use #{message}\n"}, inspect(argv)
    end
  end

  test "version names the source commit and its date" do
    assert {0, output} = CLI.execute(["version"])
    assert output =~ ~r/\Akogen [0-9a-f]{8} \(\d{4}-\d{2}-\d{2}(, uncommitted changes)?\)\n\z/

    assert Version.display("0.0.0+6e826320.20261005") == "6e826320 (2026-10-05)"

    assert Version.display("0.0.0+6e826320.20261005.dirty") ==
             "6e826320 (2026-10-05, uncommitted changes)"

    assert Version.display("0.0.0+unknown") == "unknown build (0.0.0+unknown)"
  end

  test "arguments carry positionals, flags and project options" do
    assert {:ok, approve} =
             Arguments.parse(["intent", "approve", "greet", "3fa2c1", "--by", "agent for almir"])

    assert {approve.command, approve.positionals, approve.by} ==
             {:intent_approve, ["greet", "3fa2c1"], "agent for almir"}

    assert {:ok, shape} = Arguments.parse(["intent", "shape", "greet", "-"])
    assert shape.positionals == ["greet", "-"]

    assert {:ok, start} = Arguments.parse(["queue", "start", "--detach", "--origin", "/o"])
    assert {start.command, start.detach, start.origin} == {:queue_start, true, "/o"}

    assert {:ok, status} = Arguments.parse(["status", "greet", "--watch"])
    assert {status.positionals, status.watch, status.project} == {["greet"], true, nil}

    assert {:ok, use} = Arguments.parse(["provider", "use", "chatgpt", "--as", "work"])
    assert {use.command, use.account_label, use.project} == {:provider_use, "work", nil}
  end

  test "status prints readable sections and JSON with build ids", %{tmp_dir: tmp_dir} do
    project = Git.create!(tmp_dir)
    File.mkdir_p!(Path.join(project, ".kogen"))

    File.cp!(
      Path.join(@fixture, ".kogen/project.yaml"),
      Path.join(project, ".kogen/project.yaml")
    )

    Git.git!(project, ["branch", "-M", "main"])
    intent_path = Path.join([project, ".kogen", "intents", "greet", "intent.md"])
    File.mkdir_p!(Path.dirname(intent_path))
    File.write!(intent_path, "draft Intent\n")

    assert CLI.execute(["status", "--project", project, "--base", "main"]) ==
             {0, "Queue: stopped\nDrafts:\n  greet\n"}

    assert CLI.execute(["status", "greet", "--project", project, "--base", "main"]) ==
             {0, "greet: draft; review it with kogen intent approve greet\n"}

    assert {0, json} = CLI.execute(["status", "--project", project, "--base", "main", "--json"])

    assert json ==
             ~s({"blocks_on":[],"build_id":null,"detail":null,"landed_sha":null,"priority":0,"slug":"greet","status":"draft"}\n)

    assert {0, one} = CLI.execute(["status", "greet", "--json", "--project", project])
    assert :json.decode(one)["status"] == "draft"

    assert CLI.execute(["status", "missing", "--project", project]) ==
             {2, "intent/not_found: Intent does not exist\n"}

    assert capture_io(fn ->
             assert CLI.execute(["status", "--watch", "--project", project]) == {0, ""}
           end) == "Queue: stopped\nDrafts:\n  greet\n"
  end

  test "queue stop and detach report an idle queue without writing state", %{tmp_dir: tmp_dir} do
    project = Git.create!(tmp_dir)
    File.mkdir_p!(Path.join(project, ".kogen"))

    File.cp!(
      Path.join(@fixture, ".kogen/project.yaml"),
      Path.join(project, ".kogen/project.yaml")
    )

    assert CLI.execute(["queue", "stop", "--project", project]) == {0, "queue: not running\n"}

    assert {3, detach} = CLI.execute(["queue", "start", "--detach", "--project", project])
    assert detach =~ "environment/detach_unavailable"
  end

  defp golden([]), do: File.read!(Path.join(@golden, "kogen.txt"))

  defp golden(topic),
    do: File.read!(Path.join(@golden, Enum.join(["kogen" | topic], "-") <> ".txt"))
end
