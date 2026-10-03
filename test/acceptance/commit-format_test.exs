defmodule Kogen.Acceptance.CommitFormatTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Testkit.Git

  @moduletag :acceptance
  @slug "build-engine"
  @title "Expose a ready value"

  setup_all do
    root = Kogen.Testkit.Temp.create!()
    on_exit(fn -> File.rm_rf!(root) end)
    seed = Kogen.Testkit.BuildSeed.get!(&Build.prepare_seed!/1)
    parent = Path.join(root, "landing")
    File.mkdir_p!(parent)

    result = Build.run!(parent, landing_script(), %Options{seed_project: seed})
    %{build: %{status: :landed, landed_sha: sha}} = result
    message = Git.git!(result.fixture.origin, ["show", "-s", "--format=%B", sha])

    {:ok, result: result, sha: sha, message: message}
  end

  @tag intent: "commit-format/A1"
  test "the subject is the Intent title", %{message: message} do
    assert message |> String.split("\n") |> hd() == @title
  end

  @tag intent: "commit-format/A2"
  test "the only trailer is Kogen-Intent", %{message: message} do
    body =
      message
      |> String.split("\n")
      |> tl()
      |> Enum.reject(&(String.trim(&1) == ""))

    assert body == ["Kogen-Intent: #{@slug}"]
  end

  @tag intent: "commit-format/A3"
  test "status still reports the landing", %{result: result, sha: sha} do
    fixture = result.fixture
    {:ok, statuses} = Kogen.Kernel.status(fixture.project_root, fixture.origin, "main")
    status = Enum.find(statuses, &(&1.slug == @slug))

    assert status.status == :landed
    assert status.landed_sha == sha
  end

  defp landing_script do
    [
      ScriptedProvider.answer(:context, "TinyApp.value/0 is the implementation target."),
      ScriptedProvider.answer(:plan, "Update TinyApp.value/0."),
      ScriptedProvider.write(
        :develop,
        "lib/tiny_app.ex",
        "defmodule TinyApp do\n  # revision: candidate\n  def value, do: :ready\nend\n"
      ),
      ScriptedProvider.answer(:develop, "Done."),
      ScriptedProvider.answer(:review, ~s({"verdict":"accept","findings":[]}))
    ]
  end
end
