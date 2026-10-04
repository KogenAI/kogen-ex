defmodule Kogen.Shaper.LedgerReliabilityTest do
  @moduledoc false
  use Kogen.Testkit.Case

  alias Kogen.Checks
  alias Kogen.Contracts.AcceptanceItem
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Testkit.Git

  test "an acceptance file with no tests reports the expected intent tags", %{
    tmp_dir: tmp_dir
  } do
    {project, _acceptance} = project(tmp_dir, empty_test())

    assert {:error, %Failure{class: :candidate, reason: :no_tagged_tests, detail: detail}} =
             Checks.red_on_base(
               project,
               intent(),
               Path.join(tmp_dir, "empty-run"),
               env(),
               Git.env()
             )

    assert detail == "no tests tagged intent: slug/A1"
  end

  test "an untagged acceptance test names the missing intent tag", %{tmp_dir: tmp_dir} do
    {project, _acceptance} = project(tmp_dir, untagged_test())

    assert {:error,
            %Failure{class: :candidate, reason: :acceptance_missing_on_base, detail: detail}} =
             Checks.red_on_base(
               project,
               intent(),
               Path.join(tmp_dir, "untagged-run"),
               env(),
               Git.env()
             )

    assert detail =~ "no tests tagged intent: slug/A1"
  end

  test "an acceptance compile error stays a candidate failure with compiler output", %{
    tmp_dir: tmp_dir
  } do
    {project, _acceptance} = project(tmp_dir, "defmodule BrokenAcceptanceTest do\n")

    assert {:error,
            %Failure{class: :candidate, reason: :acceptance_compile_failed, detail: detail}} =
             Checks.red_on_base(
               project,
               intent(),
               Path.join(tmp_dir, "compile-run"),
               env(),
               Git.env()
             )

    assert detail =~ "Acceptance test file failed to compile or load"
    assert detail =~ "Compilation error in file test/acceptance/slug_test.exs"
    assert detail =~ "TokenMissingError"
  end

  test "an empty report caused by a missing Erlang executable is an environment failure", %{
    tmp_dir: tmp_dir
  } do
    {project, _acceptance} = project(tmp_dir, tagged_test())
    fake_bin = Path.join(tmp_dir, "missing-erl-bin")
    File.mkdir_p!(fake_bin)
    fake_elixir = Path.join(fake_bin, "elixir")

    File.write!(
      fake_elixir,
      "#!/bin/sh\nprintf '%s\\n' 'elixir: line 245: exec: erl: not found' >&2\nexit 127\n"
    )

    File.chmod!(fake_elixir, 0o700)

    assert {:error, %Failure{class: :environment, reason: :tool_missing, detail: detail}} =
             Checks.red_on_base(
               project,
               intent(),
               Path.join(tmp_dir, "missing-erl-run"),
               Map.put(env(), "PATH", fake_bin),
               Git.env()
             )

    assert detail =~ "could not find erl"
  end

  defp project(tmp_dir, test_source) do
    project = Git.create!(Path.join(tmp_dir, "candidate"))
    File.mkdir_p!(Path.join(project, "test/acceptance"))
    File.mkdir_p!(Path.join(project, "lib"))
    File.write!(Path.join(project, ".gitignore"), "_build/\ndeps/\n")
    File.write!(Path.join(project, "mix.exs"), mix_project())
    File.write!(Path.join(project, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(
      Path.join(project, "lib/demo.ex"),
      "defmodule Demo do\n  def value, do: :new\nend\n"
    )

    acceptance = Path.join(project, "test/acceptance/slug_test.exs")
    File.write!(acceptance, test_source)
    Git.git!(project, ["add", "--all"])
    Git.git!(project, ["commit", "--quiet", "-m", "acceptance fixture"])
    {project, acceptance}
  end

  defp intent do
    %Intent{
      slug: "slug",
      title: "Test intent",
      size: :small,
      brief: "Exercise a scoped change.",
      acceptance: [%AcceptanceItem{id: "A1", text: "A1", verify: :test, domain: nil}],
      domains: ["checks"],
      notes: nil,
      path: "/tmp/slug/intent.md",
      sha256: "hash"
    }
  end

  defp env do
    {:ok, runtime} = Kogen.Kernel.runtime()
    Map.merge(Git.env(), Map.take(runtime.base_env, ["PATH", "HOME"]))
  end

  defp empty_test, do: "defmodule EmptyAcceptanceTest do\n  use ExUnit.Case, async: true\nend\n"

  defp untagged_test do
    "defmodule UntaggedAcceptanceTest do\n" <>
      "  use ExUnit.Case, async: true\n" <>
      "  test \"has no intent tag\" do\n    assert true\n  end\nend\n"
  end

  defp tagged_test do
    "defmodule TaggedAcceptanceTest do\n" <>
      "  use ExUnit.Case, async: true\n" <>
      "  @tag intent: \"slug/A1\"\n" <>
      "  test \"tagged\" do\n    assert true\n  end\nend\n"
  end

  defp mix_project do
    """
    defmodule TinyLedger.MixProject do
      use Mix.Project
      def project, do: [app: :tiny_ledger, version: "0.1.0", elixir: "~> 1.20"]
      def application, do: [extra_applications: [:logger]]
    end
    """
  end
end
