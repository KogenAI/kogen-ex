defmodule Kogen.E2e.RailsCheckBaselineTest do
  use Kogen.Testkit.Case

  alias Kogen.E2e.ScriptedProvider
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.Engine.Build.Request
  alias Kogen.Kernel.Approval
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Rails

  @moduletag :e2e
  @moduletag timeout: 300_000
  @moduletag skip: Rails.unavailable_reason()
  @slug "rails-base-red"
  @controller "app/controllers/greetings_controller.rb"

  for {new_offence?, correctable?, status} <- [
        {false, false, :landed},
        {true, false, :failed},
        {false, true, :landed}
      ] do
    if correctable? do
      @tag :correctable_base
    end

    test "base-red RuboCop #{status}: new=#{new_offence?}, correctable=#{correctable?}",
         %{tmp_dir: root} do
      {project, runtime, source} = prepare(root, unquote(correctable?))
      source = String.replace(source, ~s("old"), ~s("new"))
      source = if unquote(new_offence?), do: source <> "# lint-offence\n", else: source

      steps =
        [ScriptedProvider.write(:develop, @controller, source)] ++
          List.duplicate(ScriptedProvider.finish(), 4)

      {:ok, server} = ScriptedProvider.start_link(steps)
      on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
      assert {:ok, result} = Kogen.Kernel.build(request(root, project, runtime, server))
      assert result.status == unquote(status), inspect(result.failure)
      assert {:ok, report} = Kogen.Kernel.report(@slug, project, project, "main")
      report = :json.decode(report)

      if unquote(new_offence?) do
        assert report["last_gate"]["status"] != "pass"
      else
        assert report["last_gate"]["status"] == "pass"
        assert Enum.any?(report["last_gate"]["warnings"], &String.contains?(&1, "rubocop"))
        assert Git.git!(project, ["show", "#{result.landed_sha}:#{@controller}"]) =~ ~s("new")

        if unquote(correctable?) do
          assert Git.git!(project, ["show", "#{result.landed_sha}:test/test_helper.rb"]) =~
                   "# correctable-base-offence"

          assert File.read!(Path.join(project, "test/test_helper.rb")) =~
                   "# correctable-base-offence"
        end
      end
    end
  end

  defp prepare(root, correctable?) do
    project = Rails.project!(Path.join(root, "project"))
    home = Path.join(root, "home")
    File.mkdir_p!(home)
    runtime = Rails.runtime!(project, home)
    runs = Path.join(Kogen.Kernel.workspace_root(project, home), "runs")
    File.ln_s!(runs, Path.join(project, ".kogen/runs"))
    source = File.read!(Path.join(project, @controller)) <> "# lint-offence\n"
    File.write!(Path.join(project, @controller), source)
    File.mkdir_p!(Path.join(project, "tools"))
    File.write!(Path.join(project, "tools/rubocop"), linter())
    File.write!(Path.join(project, ".kogen/project.yaml"), profile())
    File.mkdir_p!(Path.join(project, ".kogen/intents/#{@slug}"))
    File.write!(Path.join(project, ".kogen/intents/#{@slug}/intent.md"), intent())
    File.mkdir_p!(Path.join(project, ".kogen/acceptance"))
    File.write!(Path.join(project, ".kogen/acceptance/#{@slug}_test.rb"), "")
    protected = Path.join(project, "test/test_helper.rb")
    if correctable?, do: File.write!(protected, "# correctable-base-offence\n", [:append])
    original = File.read!(protected)
    Git.git!(project, ["add", "--all"])
    Git.git!(project, ["commit", "--quiet", "-m", "Record base lint offence"])
    approve(project, runtime)
    assert File.read!(protected) == original
    {project, runtime, source}
  end

  defp approve(project, runtime) do
    {:ok, profile} = Kogen.Project.load(project)
    {:ok, env} = Kogen.Kernel.candidate_environment(project, runtime, profile)
    assert {:ok, preview} = Approval.prepare(@slug, project, project, "main", "Kogen Test", env)
    assert {:ok, _sha} = Kogen.Kernel.approve(preview)
  end

  defp request(root, project, runtime, server) do
    %Request{
      slug: @slug,
      home: Path.join(root, "home"),
      project_root: project,
      workspace_root: Kogen.Kernel.workspace_root(project, Path.join(root, "home")),
      origin: project,
      base: "main",
      model: "scripted-model",
      effort: "low",
      recipe: Kogen.Engine.build_recipe("direct", "scripted-model", "low"),
      runtime: runtime,
      provider_mod: ScriptedProvider,
      provider_config: %Config{server: server},
      credential_source: :custom,
      credential_label: "scripted"
    }
  end

  defp profile do
    """
    name: rails
    checks:
      - name: tests
        argv: [bundle, exec, rails, test]
        timeout_ms: 60000
      - name: rubocop
        argv: [ruby, tools/rubocop]
        timeout_ms: 60000
    format: [ruby, tools/rubocop, -a]
    fix:
      - name: format
        argv: [ruby, tools/rubocop, -a]
        timeout_ms: 60000
    domains:
      app: [app, test]
    """
  end

  defp linter do
    """
    count = 0
    File.readlines('#{@controller}').each_with_index do |line, index|
      next unless line.include?('# lint-offence')
      puts '#{@controller}:' + (index + 1).to_s + ':1: C: Style/Documentation: Missing documentation.'
      count += 1
    end
    puts '1 file inspected, ' + count.to_s + ' offenses detected'
    helper = 'test/test_helper.rb'
    bytes = File.read(helper)
    if bytes.include?('# correctable-base-offence')
      correction = ARGV.include?('-a') ? '[Corrected]' : '[Correctable]'
      puts helper + ':1:1: C: ' + correction + ' Layout/TrailingWhitespace: Trailing whitespace detected.'
      File.write(helper, bytes.sub("# correctable-base-offence\\n", '')) if ARGV.include?('-a')
      count += 1
    end
    exit(count == 0 ? 0 : 1)
    """
  end

  defp intent do
    """
    ---
    title: Change greeting
    domains: [app]
    size: small
    source: raw
    ---
    ## Request
    Return the new greeting without adding lint offences.
    """
  end
end
