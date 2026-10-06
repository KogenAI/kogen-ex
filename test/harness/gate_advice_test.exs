defmodule Kogen.Harness.GateAdviceTest do
  use Kogen.Testkit.Case

  alias Kogen.Checks
  alias Kogen.Contracts.Project
  alias Kogen.Harness.Gate
  alias Kogen.Harness.Opts
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Proc

  @root Path.expand("../..", __DIR__)
  @marker "# " <> "reach:" <> "disable"

  test "missing dependencies skip with notes; new reasonless suppressions block both gates", %{
    tmp_dir: tmp
  } do
    repo = fixture(tmp, [])
    base = String.trim(Git.git!(repo, ["rev-parse", "HEAD"]))

    File.write!(
      Path.join(repo, "lib/access.ex"),
      "defmodule Accessor do\n#{@marker} smells\ndef run(x), do: x.key\nend\n"
    )

    opts = options(repo, tmp, base)
    assert {:ok, gate} = Gate.run(opts, deadline())
    assert gate.status == :fail
    assert Enum.join(gate.failures) =~ "lib/access.ex:2:1"
    assert Enum.join(gate.failures) =~ "Add a reason"
    assert Enum.join(gate.warnings) =~ "dependency missing"

    assert {:ok, final} =
             Checks.run_all(repo, opts.project, Path.join(tmp, "final"), %{}, Git.env(), %{
               base: base
             })

    assert {:fail, ["reach_suppressions"]} = final.status
    assert final.feedback =~ "Add a reason"

    File.write!(
      Path.join(repo, "lib/access.ex"),
      "defmodule Accessor do\n#{@marker} smells -- intentional optional data\ndef run(x), do: x.key\nend\n"
    )

    assert {:ok, %{status: :pass}} = Gate.run(opts, deadline())
    # A quoted marker is data, not a suppression.
    File.write!(
      Path.join(repo, "lib/access.ex"),
      "defmodule Accessor do\ndef run, do: #{inspect(@marker <> " smells")}\nend\n"
    )

    assert {:ok, %{status: :pass}} = Gate.run(opts, deadline())
  end

  # Runs the external quality tools twice against an isolated project.
  @tag timeout: 180_000
  test "real tools advise on uncommitted clones and strictness changes without changing the candidate",
       %{tmp_dir: tmp} do
    repo = fixture(tmp, [:ex_dna, :reach, :ex_ast, :sourceror, :libgraph, :jason])
    base = String.trim(Git.git!(repo, ["rev-parse", "HEAD"]))
    env = tool_env(tmp)
    Proc.cmd!("mix", ["deps.compile"], cd: repo, env: Map.to_list(env))

    File.write!(
      Path.join(repo, "lib/access.ex"),
      "defmodule Accessor do\ndef run(x), do: Map.get(x, :key)\ndef fetch(x), do: Map.get(x, :key)\nend\n"
    )

    File.write!(Path.join(repo, "lib/a.ex"), clone("A"))
    File.write!(Path.join(repo, "lib/b.ex"), clone("B"))
    File.mkdir_p!(Path.join(repo, "lib/generated"))
    File.write!(Path.join(repo, "lib/generated/records.ex"), clone("Generated"))
    File.write!(Path.join(repo, "lib/marked.ex"), "# @generated\n" <> clone("Marked"))
    before = Git.git!(repo, ["status", "--porcelain"])
    opts = %{options(repo, tmp, base) | env: env}
    assert {:ok, gate} = Gate.run(opts, deadline())
    assert gate.status == :pass
    warnings = Enum.join(gate.warnings, "\n")
    assert warnings =~ "ex_dna/new_clone", logs(opts.run_dir)
    assert warnings =~ "lib/a.ex:"
    assert warnings =~ "lib/b.ex:"
    refute warnings =~ "records.ex"
    refute warnings =~ "marked.ex"
    assert warnings =~ "reach.check/strictness_downgrade"
    assert warnings =~ "run/1"
    assert warnings =~ "fetch/1"
    refute warnings =~ "Skipped:"
    assert Git.git!(repo, ["status", "--porcelain"]) == before
    assert String.trim(Git.git!(repo, ["rev-parse", "HEAD"])) == base
    Git.git!(repo, ["add", "--all"])
    Git.git!(repo, ["commit", "--quiet", "-m", "existing clones"])
    base = String.trim(Git.git!(repo, ["rev-parse", "HEAD"]))

    for path <- ["lib/a.ex", "lib/b.ex"],
        do: File.write!(Path.join(repo, path), "\n" <> File.read!(Path.join(repo, path)))

    assert {:ok, again} = Gate.run(%{opts | base: base}, deadline())
    refute Enum.join(again.warnings) =~ "ex_dna/new_clone"
    assert again.status == :pass
  end

  test "declared tools that are unavailable remain notes", %{tmp_dir: tmp} do
    repo = fixture(tmp, [])
    mix = Path.join(repo, "mix.exs")

    source =
      mix
      |> File.read!()
      |> String.replace("deps: []", ~s(deps: [{:ex_dna, "== 1.5.4"}, {:reach, "== 2.8.4"}]))

    File.write!(mix, source)
    Git.git!(repo, ["add", "--all"])
    Git.git!(repo, ["commit", "--quiet", "-m", "declare optional tools"])
    base = String.trim(Git.git!(repo, ["rev-parse", "HEAD"]))

    File.write!(
      Path.join(repo, "lib/access.ex"),
      "defmodule Accessor do\ndef run(x), do: Map.get(x, :key)\nend\n"
    )

    assert {:ok, gate} = Gate.run(options(repo, tmp, base), deadline())
    assert gate.status == :pass
    assert Enum.join(gate.warnings) =~ "Skipped: tool_unavailable"
    refute Enum.join(gate.warnings) =~ "dependency missing"
  end

  defp fixture(tmp, deps) do
    repo = Git.create!(tmp)

    entries =
      Enum.map_join(
        deps,
        ",",
        &"{#{inspect(&1)}, path: #{inspect(Path.join([@root, "deps", to_string(&1)]))}, override: true}"
      )

    File.write!(
      Path.join(repo, "mix.exs"),
      "defmodule Advice.MixProject do\nuse Mix.Project\ndef project, do: [app: :advice, version: \"0.1.0\", deps: [#{entries}]]\nend\n"
    )

    File.write!(Path.join(repo, ".gitignore"), "/_build/\n/deps/\n")
    File.mkdir_p!(Path.join(repo, "lib"))

    File.write!(
      Path.join(repo, "lib/access.ex"),
      "defmodule Accessor do\ndef run(x), do: x.key\ndef fetch(x), do: Map.fetch!(x, :key)\nend\n"
    )

    Git.git!(repo, ["add", "--all"])
    Git.git!(repo, ["commit", "--quiet", "-m", "base"])
    repo
  end

  defp clone(module) do
    """
    defmodule #{module} do
      def normalize(input) do
        input
        |> Enum.map(fn item -> String.trim(item) end)
        |> Enum.reject(fn item -> item == "" end)
        |> Enum.map(fn item -> String.downcase(item) end)
        |> Enum.sort()
        |> Enum.uniq()
        |> Enum.join(",")
      end
    end
    """
  end

  defp options(repo, tmp, base) do
    project = %Project{
      root: repo,
      name: "advice",
      checks: [],
      fix: [],
      setup: [],
      diagnose: [],
      protected_paths: [],
      domains: %{}
    }

    %Opts{
      workdir: repo,
      run_dir: Path.join(tmp, "run"),
      base: base,
      project: project,
      provider_mod: nil,
      provider_config: nil,
      proc_mod: Kogen.Proc,
      env: Git.env()
    }
  end

  defp tool_env(tmp) do
    bin = :code.root_dir() |> to_string() |> Path.join("bin")

    elixir =
      :elixir
      |> :code.which()
      |> to_string()
      |> Path.dirname()
      |> Path.join("../../../bin")
      |> Path.expand()

    Map.merge(Git.env(), %{
      "PATH" => elixir <> ":" <> bin <> ":/usr/bin:/bin",
      "HOME" => tmp,
      "MIX_ENV" => "dev",
      "MIX_ARCHIVES" => Path.expand("~/.mix/archives"),
      "HEX_HOME" => Path.join(tmp, "hex"),
      "ERL_FLAGS" => "+S 2:2"
    })
  end

  defp logs(run_dir) do
    [run_dir, "logs", "quality-*.log"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map_join("\n", &File.read!/1)
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 90_000
end
