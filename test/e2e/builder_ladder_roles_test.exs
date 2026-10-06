defmodule Kogen.E2e.BuilderLadderRolesTest do
  use Kogen.Testkit.Case

  import Kogen.E2e.Ladder, only: [done: 0, events: 2, write: 2]

  alias Kogen.E2e.Build
  alias Kogen.E2e.Build.Options
  alias Kogen.E2e.Ladder
  alias Kogen.E2e.ScriptedProvider
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.Kernel.BuildConfig
  alias Kogen.Resilience.Policy
  alias Kogen.Shaper
  alias Kogen.Shaper.Request
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Temp

  @moduletag :e2e
  @moduletag timeout: 300_000
  @plan "Difficulty: normal\n## Acceptance criteria\n1. TinyApp.value/0 returns :ready."
  @upheld ~s({"items":[{"id":"A1","verdict":"valid","reason":"The Request asks for :ready."}]})
  @recipes [
    {"ladder-luna", "gpt-6-luna", "max"},
    {"ladder-sol-low", "gpt-6.1-sol", "low"},
    {"ladder-sol-medium", "gpt-6.1-sol", "medium"},
    {"ladder-sol-high", "gpt-6.1-sol", "high"}
  ]

  setup_all do
    root = Temp.create!()
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, seed: Ladder.seed!(root)}
  end

  for {recipe, model, effort} <- @recipes do
    test "#{recipe} uses its builder through retries and every fresh and raw rung", context do
      name = unquote(recipe)
      parent = Path.join(context.tmp_dir, name)
      File.mkdir_p!(parent)

      result =
        Build.run!(parent, script(), %Options{
          seed_project: context.seed,
          recipe: name <> "+edge",
          builder_model: "ignored-builder",
          builder_effort: "low",
          resilience: %Policy{backoff_base_ms: 0, backoff_max_ms: 0}
        })

      assert result.build.status == :landed
      rows = requests(result.build.run_dir)
      builders = Enum.filter(rows, &(&1["stage"] == "develop"))

      assert Enum.uniq(Enum.map(builders, &{&1["model"], &1["effort"]})) ==
               [{unquote(model), unquote(effort)}]

      assert Enum.uniq(Enum.map(builders, & &1["attempt"])) ==
               ["builder", "fresh-2", "fresh-3", "raw-request", "fresh-3-2"]

      assert Enum.count(builders, &(&1["outcome"] == "overload")) == 2

      for stage <- ["plan", "audit", "edge"] do
        used = Enum.filter(rows, &(&1["stage"] == stage))
        assert length(used) == 3
        assert Enum.all?(used, &(&1["model"] == "gpt-6.1-sol" and &1["effort"] == "high"))
      end

      raw_index = Enum.find_index(rows, &(&1["attempt"] == "raw-request"))
      raw_text = result.provider_requests |> Enum.at(raw_index) |> Ladder.user_text()
      assert raw_text =~ "## Request"
      refute raw_text =~ "<plan>"

      assert Enum.map(events(result, "rung_finished"), & &1.attempt) ==
               ["builder", "fresh-2", "fresh-3", "raw-request", "fresh-3-2"]
    end

    test "#{recipe} shapes with Sol high independently of the builder", context do
      shape_with_defaults!(context, unquote(recipe), unquote(model), unquote(effort))
    end
  end

  defp script do
    retries(:plan) ++
      [ScriptedProvider.answer(:plan, @plan)] ++
      retries(:develop) ++
      [write("builder", :wrong), done()] ++
      retries(:audit) ++
      [ScriptedProvider.answer(:audit, @upheld), done()] ++
      Enum.flat_map(["fresh-2", "fresh-3", "raw-request"], fn rung ->
        [write(rung, :wrong), done(), done()]
      end) ++ [write("fresh-3-2", :ready), done()] ++ retries(:edge) ++ [edge_reply()]
  end

  defp retries(stage), do: List.duplicate(ScriptedProvider.fail(stage, :overload), 2)

  defp edge_reply do
    ScriptedProvider.answer(:edge, """
    ```elixir
    defmodule KogenEdge.ReadyTest do
      use ExUnit.Case, async: true
      test "returns ready repeatedly" do
        assert TinyApp.value() == :ready
        assert TinyApp.value() == :ready
      end
    end
    ```
    """)
  end

  defp shape_with_defaults!(context, recipe, model, effort) do
    project = Path.join(context.tmp_dir, recipe <> "-shape")
    Git.copy_tree!(context.seed, project)
    config_path = Path.join(project, ".kogen/project.yaml")

    File.write!(
      config_path,
      File.read!(config_path) <>
        """
        build:
          recipe: #{recipe}
          roles:
            builder:
              model: #{model}
              effort: #{effort}
            shaper:
              effort: high
        """
    )

    {:ok, project_config} = Kogen.Project.load(project)
    {:ok, settings} = BuildConfig.load(Path.join(context.tmp_dir, "home"), project_config.build)
    {shape_model, shape_effort} = BuildConfig.shape_settings(settings.roles)
    run_dir = Path.join(context.tmp_dir, recipe <> "-shape-run")
    {:ok, server} = ScriptedProvider.start_link([shape_reply(project)])
    config = %Config{server: server}

    try do
      assert {:ok, _result} =
               Shaper.shape(shape_request(project, run_dir, config, shape_model, shape_effort))

      assert [%{"stage" => "shape", "model" => "gpt-6.1-sol", "effort" => "high"}] =
               requests(run_dir)

      assert [%{model: "gpt-6.1-sol", effort: "high"}] = ScriptedProvider.requests(config)
    after
      GenServer.stop(server, :normal)
    end
  end

  defp shape_reply(project) do
    intent_path = ".kogen/intents/build-engine/intent.md"
    acceptance_path = ".kogen/acceptance/build-engine_test.exs"
    intent = project |> Path.join(intent_path) |> File.read!()

    intent =
      String.replace(
        intent,
        "Keep the implementation inside lib/tiny_app.ex.",
        "Approach: Change TinyApp.value/0 in lib/tiny_app.ex to return :ready and preserve its public function."
      )

    acceptance = project |> Path.join(acceptance_path) |> File.read!()
    ScriptedProvider.write_many(:shape, [{intent_path, intent}, {acceptance_path, acceptance}])
  end

  defp shape_request(project, run_dir, config, model, effort) do
    {:ok, runtime} = Kogen.Kernel.runtime()

    %Request{
      workdir: project,
      slug: "build-engine",
      task: "Make TinyApp.value/0 return :ready.",
      model: model,
      effort: effort,
      provider_mod: ScriptedProvider,
      provider_config: config,
      env: Map.put(runtime.base_env, "MIX_ENV", "test"),
      git_env: Git.env(),
      run_dir: run_dir
    }
  end

  defp requests(run_dir) do
    run_dir
    |> Path.join("requests.jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&:json.decode/1)
    |> Enum.filter(&(&1["record_kind"] == "model_request" and is_integer(&1["started_at"])))
  end
end
