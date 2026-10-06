defmodule Kogen.Checks.RailsLedgerTest do
  use Kogen.Testkit.Case

  alias Kogen.Checks
  alias Kogen.Contracts.AcceptanceItem
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.ProcResult
  alias Kogen.Proc
  alias Kogen.Project
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Rails

  @moduletag timeout: 180_000
  @moduletag skip: Rails.unavailable_reason()

  test "missing and skipped Minitest items cannot pass acceptance or prove red on the base", %{
    tmp_dir: root
  } do
    project = Rails.project!(Path.join(root, "project with spaces"))
    {:ok, profile} = Project.load(project)
    env = Rails.environment!(project, Path.join(root, "home"), profile)

    assert {:ok, %ProcResult{exit_status: 0}} =
             Proc.run(["bundle", "install", "--local"],
               cd: project,
               env: env,
               timeout_ms: 120_000
             )

    intent = intent()
    path = Path.join(project, "test/acceptance/outcomes_test.rb")
    File.mkdir_p!(Path.dirname(path))
    run_dir = Path.join(root, "ledger with spaces")

    File.write!(path, source(:missing))

    assert {:ok, %{status: {:fail, ["A2"]}}} =
             Checks.acceptance(project, intent, run_dir, env, Git.env())

    File.write!(path, source(:skipped))

    assert {:ok, %{status: {:fail, ["A1"]}, ledger: rows}} =
             Checks.acceptance(project, intent, run_dir, env, Git.env())

    assert Enum.any?(rows, &(&1.tag == "outcomes/A1" and &1.status == :skipped))

    assert {:error, %{reason: :not_red_on_base}} =
             Checks.red_on_base(project, intent, run_dir, env, Git.env())

    File.write!(path, source(:unknown))

    assert {:ok, %{status: {:fail, ids}}} =
             Checks.acceptance(project, intent, run_dir, env, Git.env())

    assert "outcomes/A3" in ids
  end

  defp intent do
    %Intent{
      slug: "outcomes",
      title: "Verify outcomes",
      size: :small,
      brief: "Verify outcomes.",
      acceptance: [
        %AcceptanceItem{id: "A1", text: "First outcome", verify: :test, domain: "app"},
        %AcceptanceItem{id: "A2", text: "Second outcome", verify: :test_keep, domain: "app"}
      ],
      domains: ["app"],
      notes: nil,
      path: ".kogen/intents/outcomes/intent.md",
      sha256: "fixture"
    }
  end

  defp source(mode) do
    first = if mode == :skipped, do: "skip 'not implemented'", else: "assert true"
    second = if mode == :missing, do: "", else: "def test_A2_outcome; assert true; end"
    extra = if mode == :unknown, do: "def test_A3_outcome; assert true; end", else: ""

    """
    require "test_helper"
    class OutcomesTest < ActiveSupport::TestCase
      def test_A1_outcome
        #{first}
      end
      #{second}
      #{extra}
    end
    """
  end
end
