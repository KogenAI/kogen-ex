defmodule Kogen.E2e.RailsBundleSetupTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.Failure
  alias Kogen.Engine
  alias Kogen.Engine.Build.Setup
  alias Kogen.Proc
  alias Kogen.Proc.Sandbox
  alias Kogen.Project
  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Rails

  @moduletag :e2e
  @moduletag timeout: 300_000
  @moduletag skip: Rails.unavailable_reason()

  for selection <- ["BUNDLE_PATH", "GEM_HOME", "BUNDLE_APP_CONFIG"] do
    test "offline Rails setup uses the seeded cache selected by #{selection}", %{tmp_dir: root} do
      {project, profile, runtime} = fixture(root)
      runtime = select_cache(runtime, root, unquote(selection))
      assert {:ok, env} = Engine.candidate_environment(project, runtime, profile)
      assert :ok = run_setup(profile, root, env, "seed-run")
      File.rm_rf!(Path.join(project, "vendor/cache"))
      lock = File.read!(Path.join(project, "Gemfile.lock"))
      assert :ok = run_setup(profile, root, env, "build-run")

      assert {:ok, %{exit_status: 0, output_tail: output}} =
               Proc.run(["bundle", "exec", "rails", "test"], cd: project, env: env)

      assert output =~ "0 failures, 0 errors"
      assert File.read!(Path.join(project, "Gemfile.lock")) == lock
      refute File.exists?(Path.join(project, ".bundle/gems"))
    end
  end

  test "offline setup names a missing gem and leaves the lockfile unchanged", %{tmp_dir: root} do
    {project, profile, runtime} = fixture(root)
    profile = %{profile | env: %{"BUNDLE_AUTO_INSTALL" => "true"}}
    File.rm!(Path.join(project, "vendor/cache/minitest-5.25.4.gem"))
    runtime = select_cache(runtime, root, "BUNDLE_PATH")
    assert {:ok, env} = Engine.candidate_environment(project, runtime, profile)
    lock = File.read!(Path.join(project, "Gemfile.lock"))

    assert {:error, %Failure{class: :environment, reason: :setup_failed, detail: detail}} =
             run_setup(profile, root, env, "build-run")

    assert detail =~ "minitest"
    refute detail =~ "Fetching"
    assert File.read!(Path.join(project, "Gemfile.lock")) == lock
  end

  test "offline setup reuses a git gem checkout without a bare Git cache", %{tmp_dir: root} do
    {project, profile, runtime} = fixture(root)
    runtime = select_cache(runtime, root, "GEM_HOME")
    seed_git_gem(root, project, runtime.base_env["GEM_HOME"])
    refute File.exists?(Path.join(runtime.base_env["GEM_HOME"], "cache/bundler/git"))
    assert {:ok, env} = Engine.candidate_environment(project, runtime, profile)
    assert :ok = run_setup(profile, root, env, "build-run")

    assert {:ok, %{exit_status: 0, output_tail: "seeded\n"}} =
             Proc.run(["bundle", "exec", "ruby", "-rcached_greeting", "-e", "puts GREETING"],
               cd: project,
               env: env
             )

    refute File.read!(Path.join(root, "build-run/logs/setup-bundle.log")) =~ "Fetching"
  end

  test "setup refuses to resolve changed dependencies in a frozen bundle", %{tmp_dir: root} do
    {project, profile, runtime} = fixture(root)
    File.write!(Path.join(project, "Gemfile"), "gem 'missing_locked_gem'\n")
    assert {:ok, env} = Engine.candidate_environment(project, runtime, profile)
    lock = File.read!(Path.join(project, "Gemfile.lock"))

    assert {:error, %Failure{reason: :setup_failed, detail: detail}} =
             run_setup(profile, root, env, "build-run")

    assert detail =~ "frozen"
    assert File.read!(Path.join(project, "Gemfile.lock")) == lock
  end

  defp run_setup(profile, root, env, name) do
    run_dir = Path.join(root, name)

    sandbox = %Sandbox{
      enabled: true,
      home: Path.join(root, "home"),
      project_root: profile.root,
      origin: profile.root,
      workspace: profile.root,
      run_dir: run_dir,
      tmp_dir: root,
      workspace_is_project: true
    }

    Setup.run(profile.setup, profile.root, run_dir, env, Proc, sandbox)
  end

  defp fixture(root) do
    project = Rails.project!(Path.join(root, "project"))
    home = Path.join(root, "home")
    File.mkdir_p!(home)
    runtime = Rails.runtime!(project, home)
    assert {:ok, profile} = Project.load(project)
    {project, profile, runtime}
  end

  defp select_cache(runtime, root, selection) do
    cache = Path.join(root, "seeded-gems")

    settings =
      case selection do
        "BUNDLE_APP_CONFIG" ->
          config = Path.join(root, "bundle-config")
          File.mkdir_p!(config)
          File.write!(Path.join(config, "config"), "---\nBUNDLE_PATH: #{cache}\n")
          %{"BUNDLE_APP_CONFIG" => config}

        key ->
          %{key => cache, "GEM_PATH" => cache}
      end

    env =
      runtime.base_env
      |> Map.drop(["BUNDLE_PATH", "GEM_HOME", "GEM_PATH", "BUNDLE_APP_CONFIG"])
      |> Map.merge(settings)
      |> Map.merge(%{
        "http_proxy" => "http://127.0.0.1:1",
        "https_proxy" => "http://127.0.0.1:1",
        "GIT_ALLOW_PROTOCOL" => "file"
      })

    %{runtime | base_env: env}
  end

  defp seed_git_gem(root, project, cache) do
    source = Path.join(root, "cached_greeting")
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "lib/cached_greeting.rb"), "GREETING = 'seeded'\n")

    File.write!(Path.join(source, "cached_greeting.gemspec"), """
    Gem::Specification.new do |s|
      s.name = 'cached_greeting'
      s.version = '1.0.0'
      s.summary = 'Offline fixture'
      s.authors = ['Kogen Test']
      s.files = ['lib/cached_greeting.rb']
    end
    """)

    Git.git!(source, ["init", "--quiet", "--template="])
    Git.git!(source, ["add", "--all"])
    Git.git!(source, ["commit", "--quiet", "-m", "Seed cached git gem"])
    revision = source |> Git.git!(["rev-parse", "HEAD"]) |> String.trim()
    checkout = Path.join(cache, "bundler/gems/cached_greeting-#{String.slice(revision, 0, 12)}")
    File.mkdir_p!(Path.dirname(checkout))
    File.cp_r!(source, checkout)
    url = "https://offline.invalid/cached_greeting.git"

    File.write!(
      Path.join(project, "Gemfile"),
      "source 'https://rubygems.org'\ngem 'cached_greeting', git: '#{url}'\n"
    )

    write_git_lock(project, url, revision)
  end

  defp write_git_lock(project, url, revision) do
    File.write!(Path.join(project, "Gemfile.lock"), """
    GIT
      remote: #{url}
      revision: #{revision}
      specs:
        cached_greeting (1.0.0)

    GEM
      remote: https://rubygems.org/
      specs:

    PLATFORMS
      ruby

    DEPENDENCIES
      cached_greeting!

    BUNDLED WITH
       2.6.9
    """)
  end
end
