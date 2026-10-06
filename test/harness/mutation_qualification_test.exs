defmodule Kogen.Harness.MutationQualificationTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.Project
  alias Kogen.Harness.Gate
  alias Kogen.Harness.Opts
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.HarnessScriptedProvider

  test "survivors identify changed locations and tests while the candidate and gate stay green",
       %{tmp_dir: tmp} do
    {repo, opts} = fixture(tmp)
    path = Path.join(repo, "lib/value.ex")

    File.write!(
      path,
      "defmodule Value do\ndef positive?(n), do: n >= 0\nend\n# mutation-ignore\n"
    )

    File.write!(
      Path.join(repo, "test/value_test.exs"),
      "defmodule ValueTest do\nuse ExUnit.Case\ntest \"positive\", do: assert(Value.positive?(1))\nend\n"
    )

    assert {:ok, gate} = Gate.run(opts, deadline())
    assert gate.status == :pass
    report = report(tmp)
    assert report["complete"]

    assert [
             %{
               "status" => "survived",
               "path" => "lib/value.ex",
               "line" => 2,
               "tests" => ["test/value_test.exs"]
             }
           ] = report["trials"]

    assert Enum.join(gate.warnings) =~ "Add an assertion distinguishing"
    assert Enum.join(gate.warnings) =~ "Mutation-ignore"
    assert report["wall_ms"] > 0
    assert report["baseline"]["exit_status"] == 0
    # The behavior at the changed boundary distinguishes the mutant.
    File.write!(
      Path.join(repo, "test/value_test.exs"),
      "defmodule ValueTest do\nuse ExUnit.Case\ntest \"boundary\", do: assert(Value.positive?(0))\nend\n"
    )

    assert {:ok, %{status: :pass}} = Gate.run(opts, deadline())
    assert [%{"status" => "killed"}] = report(tmp)["trials"]

    assert Kogen.Testkit.Proc.cmd!(
             "elixir",
             ["-r", "lib/value.ex", "-e", "IO.inspect(Value.positive?(0))"],
             cd: repo
           ) == "true\n"
  end

  test "deadline exhaustion is incomplete advice and never claims full qualification", %{
    tmp_dir: tmp
  } do
    {repo, opts} = fixture(tmp)

    File.write!(
      Path.join(repo, "lib/value.ex"),
      "defmodule Value do\ndef positive?(n), do: n >= 0\nend\n"
    )

    assert {:ok, gate} = Gate.run(opts, System.monotonic_time(:millisecond))
    assert gate.status == :pass
    assert Enum.join(gate.warnings) =~ "diff unavailable"
  end

  test "survivors return to the same builder as advisory feedback", %{tmp_dir: tmp} do
    {repo, opts} = fixture(tmp)

    File.write!(
      Path.join(repo, "lib/value.ex"),
      "defmodule Value do\ndef positive?(n), do: n >= 0\nend\n"
    )

    File.write!(
      Path.join(repo, "test/value_test.exs"),
      "defmodule ValueTest do\nuse ExUnit.Case\ntest \"positive\", do: assert(Value.positive?(1))\nend\n"
    )

    provider =
      HarnessScriptedProvider.start([
        %ModelResponse{
          id: "fixture",
          text: "",
          tool_calls: [%Kogen.Contracts.ToolCall{id: "finish", name: "finish", arguments: %{}}],
          raw_items: [],
          usage: %{}
        },
        %ModelResponse{
          id: "fixture",
          text: "Add a zero boundary assertion.",
          tool_calls: [],
          raw_items: [],
          usage: %{}
        }
      ])

    opts = %{
      opts
      | provider_mod: HarnessScriptedProvider,
        provider_config: provider,
        changed?: fn -> {:ok, true} end
    }

    assert {:ok, result} = Kogen.Harness.develop(opts, "Make zero positive.", nil, nil)
    assert result.outcome == :done
    assert result.gate.status == :pass
    [build, advice] = HarnessScriptedProvider.requests(provider)
    assert advice.model == build.model
    refute advice.prompt_cache_key == build.prompt_cache_key
    assert advice.tools == []
    assert File.read!(result.transcript_path) =~ "Advisory mutation qualification"
    assert File.read!(result.transcript_path) =~ "Add a zero boundary assertion"
  end

  test "trial caps report partial qualification", %{tmp_dir: tmp} do
    {repo, opts} = fixture(tmp)
    functions = Enum.map_join(1..7, "\n", &"def positive#{&1}?(n), do: n >= 0")
    File.write!(Path.join(repo, "lib/value.ex"), "defmodule Value do\n" <> functions <> "\nend\n")

    File.write!(
      Path.join(repo, "test/value_test.exs"),
      "defmodule ValueTest do\nuse ExUnit.Case\ntest \"positive\", do: assert(Value.positive1?(1))\nend\n"
    )

    assert {:ok, %{status: :pass}} = Gate.run(opts, deadline())
    report = report(tmp)
    assert report["eligible"] == 7
    assert length(report["trials"]) <= 6
    refute report["complete"]
  end

  defp fixture(tmp) do
    repo = Git.create!(Path.join(tmp, "repo"))
    File.mkdir_p!(Path.join(repo, "lib"))
    File.mkdir_p!(Path.join(repo, "test"))

    File.write!(
      Path.join(repo, "mix.exs"),
      "defmodule MutationFixture.MixProject do\nuse Mix.Project\ndef project, do: [app: :mutation_fixture, version: \"0.1.0\"]\nend\n"
    )

    File.write!(Path.join(repo, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(
      Path.join(repo, "lib/value.ex"),
      "defmodule Value do\ndef positive?(n), do: n > 0\nend\n"
    )

    File.write!(Path.join(repo, ".gitignore"), "_build/\n")
    Git.git!(repo, ["add", "--all"])
    Git.git!(repo, ["commit", "-qm", "seed"])
    base = String.trim(Git.git!(repo, ["rev-parse", "HEAD"]))

    opts = options(repo, tmp, base)
    {repo, opts}
  end

  defp options(repo, tmp, base) do
    opts = %Opts{
      workdir: repo,
      run_dir: Path.join(tmp, "run"),
      base: base,
      project: %Project{
        root: repo,
        name: "mutation",
        checks: [],
        fix: [],
        setup: [],
        diagnose: [],
        protected_paths: [],
        domains: %{}
      },
      provider_mod: Kogen.Provider.Fake,
      provider_config: nil,
      proc_mod: Kogen.Proc,
      env: Map.merge(Git.env(), %{"PATH" => tool_path(), "HOME" => tmp, "ERL_FLAGS" => "+S 2:2"})
    }

    opts
  end

  defp tool_path do
    elixir =
      :elixir
      |> :code.which()
      |> to_string()
      |> Path.dirname()
      |> Path.join("../../../bin")
      |> Path.expand()

    elixir <> ":" <> Path.join(to_string(:code.root_dir()), "bin") <> ":/usr/bin:/bin"
  end

  defp report(tmp),
    do: tmp |> Path.join("run/mutation-qualification.json") |> File.read!() |> JSON.decode!()

  defp deadline, do: System.monotonic_time(:millisecond) + 24_000
end
