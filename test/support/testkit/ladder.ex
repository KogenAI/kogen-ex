defmodule Kogen.E2e.Ladder do
  @moduledoc "Script steps and journal readers for ladder recipe Builds in e2e tests."

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Build.Result
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.State.Event
  alias Kogen.Testkit.Git

  @spec run!(Path.t(), String.t(), [ScriptedProvider.Step.t()], Path.t(), String.t(), map()) ::
          Result.t()
  def run!(tmp_dir, name, script, seed, recipe \\ "ladder", ladder \\ %{}) do
    parent = Path.join(tmp_dir, name)
    File.mkdir_p!(parent)

    Build.run!(parent, script, %Options{
      seed_project: seed,
      recipe: recipe,
      builder_model: "gpt-6-luna",
      builder_effort: "max",
      ladder: ladder
    })
  end

  @doc "A shell step that rewrites lib/tiny_app.ex with a revision marker and comment lines."
  @spec write(String.t(), atom(), [String.t()]) :: ScriptedProvider.Step.t()
  def write(revision, value, markers \\ []) do
    lines = Enum.map_join(markers, &"  # #{&1}\n")

    source =
      "defmodule TinyApp do\n  # revision: #{revision}\n#{lines}  def value, do: :#{value}\nend\n"

    shell("cat > lib/tiny_app.ex <<'EOF'\n#{source}EOF")
  end

  @spec shell(String.t()) :: ScriptedProvider.Step.t()
  def shell(command), do: ScriptedProvider.call(:develop, "shell", %{"cmd" => command})

  @spec done() :: ScriptedProvider.Step.t()
  def done, do: ScriptedProvider.answer(:develop, "Done.")

  @spec events(Result.t(), String.t()) :: [Event.t()]
  def events(result, name), do: Enum.filter(result.events, &(&1.event == name))

  @spec stage_events(Result.t(), String.t()) :: [Event.t()]
  def stage_events(result, stage),
    do: Enum.filter(events(result, "model_stage"), &(&1.stage == stage))

  @spec source_at(Result.t(), String.t()) :: String.t()
  def source_at(result, rev),
    do: Git.git!(result.fixture.origin, ["show", "#{rev}:lib/tiny_app.ex"])

  @spec user_text(map()) :: String.t()
  def user_text(%{input: [%{"role" => "user", "content" => [%{"text" => text}]} | _rest]}),
    do: text

  @doc "Seeds the tiny project with `tests_project/0` and a passing base test, plus `options`."
  @spec seed!(Path.t(), keyword()) :: Path.t()
  def seed!(root, options \\ []) do
    base_test = """
    defmodule TinyApp.BaseTest do
      use ExUnit.Case, async: true

      test "the module loads" do
        assert Code.ensure_loaded?(TinyApp)
      end
    end
    """

    Build.prepare_seed!(
      root,
      [project_config: tests_project(), extra_files: %{"test/tiny_app_test.exs" => base_test}] ++
        options
    )
  end

  @doc "A tiny project whose only check is `mix test`, so acceptance tests run in the gate."
  @spec tests_project() :: String.t()
  def tests_project do
    """
    name: tiny_app
    checks:
      - name: tests
        argv: [mix, test]
        timeout_ms: 60000
    fix: []
    domains:
      kernel: [lib]
    """
  end
end
