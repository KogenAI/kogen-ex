defmodule Kogen.E2e.ShapingRecheckTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.IntentFixture
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.Kernel.CLI.StatusOutput
  alias Kogen.Queue.BuildSummary
  alias Kogen.State
  alias Kogen.Testkit.Git

  @moduletag :e2e
  @moduletag timeout: 300_000

  test "a changed product boundary stops before Build and is explained in status", %{tmp_dir: dir} do
    {fixture, request, server} = prepare!(dir, "")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    advance!(fixture, "Members only.\n")

    assert {:ok, result} = Kogen.Kernel.build(request)
    assert result.reason == :shaping_stale
    assert Enum.join(result.lines) =~ "Changed assumption guests can browse"
    assert ScriptedProvider.requests(request.provider_config) == []
    {:ok, run} = State.load(fixture.workspace_root, result.run_id)
    events = File.read!(Path.join(run.dir, "events.jsonl"))
    assert events =~ "shaping_stale"
    refute events =~ ~s("event":"started")
    {:ok, summary} = BuildSummary.latest(fixture.workspace_root, request.slug)
    assert StatusOutput.build_text(summary) =~ "Reshape the Intent or renew approval"
  end

  test "unrelated base edits and landed dependencies retain approval and the Build starts", %{
    tmp_dir: dir
  } do
    {fixture, request, server} = prepare!(dir, "blocks_on: [browse-access]\n")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    advance!(fixture, "Guests may browse.\nUnrelated help copy.\n")

    assert {:started, session, _effects} = Kogen.Engine.start(request)
    assert session.base_sha != fixture.approved_base
    events = File.read!(Path.join(session.run.dir, "events.jsonl"))
    assert events =~ "shaping_rechecked"
    assert events =~ "landed_sha"
    assert events =~ ~s("event":"started")
    assert :ok = State.release(fixture.origin, session.run.id, Git.env())
  end

  test "an unlanded dependency requires caller attention before Build", %{tmp_dir: dir} do
    {fixture, request, server} = prepare!(dir, "blocks_on: [browse-access]\n")
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

    assert {:ok, result} = Kogen.Kernel.build(request)
    assert result.reason == :shaping_stale
    assert Enum.join(result.lines) =~ "dependency has no landed outcome"
    assert ScriptedProvider.requests(request.provider_config) == []
    refute File.dir?(Path.join(fixture.workspace_root, "candidates"))
  end

  defp prepare!(dir, dependency) do
    frontmatter = """
    size: small
    #{dependency}assumptions:
      - name: guests can browse
        path: docs/access.md
        contains: Guests may browse.
    shared_contracts:
      - name: response contract
        path: docs/api.md
        contains: Creation returns 201.
    """

    intent = String.replace(IntentFixture.intent(), "size: small\n", frontmatter)

    seed =
      Build.prepare_seed!(dir,
        intent: intent,
        extra_files: %{
          "docs/access.md" => "Guests may browse.\n",
          "docs/api.md" => "Creation returns 201.\n"
        }
      )

    {:ok, server} = ScriptedProvider.start_link([])
    {fixture, request} = Build.prepare!(dir, seed, server)
    {fixture, request, server}
  end

  defp advance!(fixture, contract) do
    File.write!(Path.join(fixture.project_root, "docs/access.md"), contract)
    Git.git!(fixture.project_root, ["add", "docs/access.md"])

    Git.git!(fixture.project_root, [
      "commit",
      "--quiet",
      "-m",
      "Update product boundary\n\nKogen-Intent: browse-access"
    ])

    Git.git!(fixture.project_root, ["push", "--quiet", "origin", "main"])
  end
end
