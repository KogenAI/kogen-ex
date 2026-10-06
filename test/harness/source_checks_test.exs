defmodule Kogen.Harness.SourceChecksTest do
  use Kogen.Testkit.Case

  alias Kogen.Checks
  alias Kogen.Contracts.CheckBaseline
  alias Kogen.Contracts.Project
  alias Kogen.Harness.Gate
  alias Kogen.Harness.Opts
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Proc

  test "compile-time reads block until their resource is declared, and file edits recompile", %{
    tmp_dir: tmp
  } do
    repo = fixture(tmp)
    File.write!(Path.join(repo, "lib/data.txt"), "old\n")
    File.write!(Path.join(repo, "lib/reader.ex"), reader(false))

    opts = %{
      options(repo, tmp)
      | changed_ranges: fn -> {:ok, ["lib/reader.ex: base 0 -> candidate 1-6"]} end
    }

    assert {:ok, gate} = Gate.run(opts, deadline())
    assert gate.status == :fail
    assert Enum.join(gate.failures) =~ "lib/reader.ex:4:1"
    assert Enum.join(gate.failures) =~ "Declare @external_resource for lib/data.txt"
    assert Enum.join(gate.failures) =~ "Candidate changes relative to Build base:"
    assert Enum.join(gate.failures) =~ "lib/reader.ex: base 0 -> candidate 1-6"

    assert {:ok, final} =
             Checks.run_all(repo, opts.project, Path.join(tmp, "final"), %{}, Git.env(), %{
               changed_ranges: opts.changed_ranges
             })

    assert {:fail, ["source_checks"]} = final.status
    assert final.feedback =~ "Candidate changes relative to Build base:"
    assert final.feedback =~ "lib/reader.ex: base 0 -> candidate 1-6"
    File.write!(Path.join(repo, "lib/reader.ex"), reader(true))
    assert {:ok, %{status: :pass}} = Gate.run(opts, deadline())
    assert repo |> run_reader(tmp) |> String.ends_with?("old\n\n")
    File.write!(Path.join(repo, "lib/data.txt"), "fresh resource content\n")
    assert repo |> run_reader(tmp) |> String.ends_with?("fresh resource content\n\n")
  end

  test "source failures recorded at approval are excused in both gates, while new ones fail", %{
    tmp_dir: tmp
  } do
    repo = fixture(tmp)
    File.write!(Path.join(repo, "lib/data.txt"), "old\n")
    File.write!(Path.join(repo, "lib/reader.ex"), reader(false))
    opts = options(repo, tmp)
    run_dir = Path.join(tmp, "final")
    assert {:ok, base} = Checks.run_all(repo, opts.project, run_dir, %{}, Git.env())
    baseline = CheckBaseline.from_assessments(base.checks)
    opts = %{opts | check_baseline: baseline}
    final_options = %{check_baseline: baseline}

    assert {:ok, gate} = Gate.run(opts, deadline())
    assert gate.status == :pass
    assert Enum.join(gate.warnings) =~ "Base-red warning"

    assert {:ok, final} =
             Checks.run_all(repo, opts.project, run_dir, %{}, Git.env(), final_options)

    assert final.status == :pass
    assert Enum.join(final.warnings) =~ "Base-red warning"
    File.write!(Path.join(repo, "lib/another.ex"), reader(false))
    assert {:ok, gate} = Gate.run(opts, deadline())
    assert gate.status == :fail

    assert {:ok, final} =
             Checks.run_all(repo, opts.project, run_dir, %{}, Git.env(), final_options)

    assert {:fail, ["source_checks"]} = final.status
  end

  test "three repeated public map contracts are advice in both gates without optional tools", %{
    tmp_dir: tmp
  } do
    repo = fixture(tmp)

    for name <- ["A", "B", "C"] do
      File.write!(
        Path.join(repo, "lib/#{String.downcase(name)}.ex"),
        "defmodule #{name} do\ndef run, do: %{a: 1, b: 2, c: 3, d: 4}\nend\n"
      )
    end

    opts = options(repo, tmp)
    assert {:ok, gate} = Gate.run(opts, deadline())
    assert gate.status == :pass
    assert length(gate.warnings) == 3
    assert Enum.join(gate.warnings) =~ "lib/a.ex:2: warning:"
    assert Enum.join(gate.warnings) =~ "RepeatedMapShape"
    assert Enum.join(gate.warnings) =~ "struct"

    assert {:ok, final} =
             Checks.run_all(repo, opts.project, Path.join(tmp, "final"), %{}, Git.env())

    assert final.status == :pass
    assert length(final.warnings) == 3
    assert final.feedback =~ "RepeatedMapShape"
  end

  test "implementation assertions are inventoried as advice without blocking a refactor", %{
    tmp_dir: tmp
  } do
    repo = fixture(tmp)
    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join(repo, "test/pinned_test.exs"), ~s{defmodule PinnedTest do
use ExUnit.Case
test "spelling", do: assert(File.read!("lib/app.ex") =~ "def value")
end
})
    opts = options(repo, tmp)
    assert {:ok, gate} = Gate.run(opts, deadline())
    assert gate.status == :pass
    assert Enum.join(gate.warnings) =~ "test/pinned_test.exs:3"
    assert Enum.join(gate.warnings) =~ "Execute the interface"
    File.write!(Path.join(repo, "test/pinned_test.exs"), ~s{defmodule PinnedTest do
use ExUnit.Case
test "value", do: assert(App.value() == :ready)
end
})
    assert {:ok, gate} = Gate.run(opts, deadline())
    refute Enum.join(gate.warnings) =~ "implementation_text"
  end

  defp fixture(tmp) do
    repo = Git.create!(tmp)
    File.mkdir_p!(Path.join(repo, "lib"))

    File.write!(
      Path.join(repo, "mix.exs"),
      "defmodule SourceFixture.MixProject do\nuse Mix.Project\ndef project, do: [app: :source_fixture, version: \"0.1.0\"]\nend\n"
    )

    File.write!(Path.join(repo, ".gitignore"), "/_build/\n")
    repo
  end

  defp reader(resource?) do
    resource = if resource?, do: "@external_resource @path", else: ""

    """
    defmodule Reader do
      @path Path.join(__DIR__, "data.txt")
      #{resource}
      @data File.read!(@path)
      def value, do: @data
    end
    """
  end

  defp options(repo, tmp) do
    project = %Project{
      root: repo,
      name: "source",
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
      project: project,
      provider_mod: nil,
      provider_config: nil,
      proc_mod: Kogen.Proc,
      env: Git.env()
    }
  end

  defp run_reader(repo, tmp) do
    env = Map.merge(Git.env(), %{"HOME" => tmp, "MIX_ENV" => "dev", "ERL_FLAGS" => "+S 2:2"})

    Proc.cmd!("mix", ["run", "--no-start", "-e", "IO.puts(Reader.value())"],
      cd: repo,
      env: Map.to_list(env)
    )
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 60_000
end
