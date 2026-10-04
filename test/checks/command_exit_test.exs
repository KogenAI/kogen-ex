defmodule Kogen.Checks.CommandExitTest do
  use Kogen.Testkit.Case

  alias Kogen.Checks
  alias Kogen.Contracts.AcceptanceItem
  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.Project
  alias Kogen.Proc.Sandbox
  alias Kogen.Testkit.Git

  test "check exit statuses 126 and 127 are environment failures", %{tmp_dir: tmp_dir} do
    for status <- [126, 127] do
      repo = Git.create!(Path.join(tmp_dir, "check-#{status}"))

      spec = %CheckSpec{
        name: "unavailable",
        argv: ["/bin/sh", "-c", "exit #{status}"],
        timeout_ms: 5_000
      }

      project = %Project{
        root: repo,
        name: "test-project",
        checks: [spec],
        setup: [],
        fix: [],
        diagnose: [],
        protected_paths: [],
        domains: %{}
      }

      assert {:error, %Failure{class: :environment, reason: :tool_missing}} =
               Checks.run_all(
                 repo,
                 project,
                 Path.join(tmp_dir, "check-run-#{status}"),
                 Git.env()
               )
    end
  end

  test "safe formatter exit statuses 126 and 127 are environment tool failures", %{
    tmp_dir: tmp_dir
  } do
    for status <- [126, 127] do
      repo = Git.create!(Path.join(tmp_dir, "fix-#{status}"))

      project = %Project{
        root: repo,
        name: "test-project",
        checks: [],
        setup: [],
        fix: [
          %CheckSpec{
            name: "formatter",
            argv: ["/bin/sh", "-c", "exit #{status}"],
            timeout_ms: 5_000
          }
        ],
        diagnose: [],
        protected_paths: [],
        domains: %{}
      }

      assert {:error, %Failure{class: :environment, reason: :tool_missing}} =
               Kogen.Checks.Fixer.run(
                 repo,
                 project,
                 Path.join(tmp_dir, "fix-run-#{status}"),
                 Git.env()
               )
    end
  end

  test "acceptance runner exit statuses 126 and 127 are environment failures", %{
    tmp_dir: tmp_dir
  } do
    repo = Git.create!(Path.join(tmp_dir, "acceptance"))
    test_path = Path.join([repo, "test", "acceptance", "slug_test.exs"])
    bin_dir = Path.join(tmp_dir, "runtime-bin")
    elixir = Path.join(bin_dir, "elixir")
    File.mkdir_p!(Path.dirname(test_path))
    File.mkdir_p!(bin_dir)
    File.write!(test_path, "ExUnit.start()\n")
    Git.git!(repo, ["add", "--all"])
    Git.git!(repo, ["commit", "--quiet", "-m", "acceptance fixture"])

    intent = %Intent{
      slug: "slug",
      title: "Test acceptance",
      size: :small,
      brief: "Exercise the acceptance runner.",
      acceptance: [%AcceptanceItem{id: "A1", text: "Runs the suite.", verify: :test, domain: nil}],
      domains: [],
      notes: nil,
      path: ".kogen/intents/slug/intent.md",
      sha256: "fixture"
    }

    for status <- [126, 127] do
      File.write!(elixir, "#!/bin/sh\nexit #{status}\n")
      File.chmod!(elixir, 0o755)

      assert {:error, %Failure{class: :environment, reason: :tool_missing}} =
               Checks.acceptance(
                 repo,
                 intent,
                 Path.join(tmp_dir, "acceptance-run-#{status}"),
                 %{"PATH" => bin_dir},
                 Git.env()
               )
    end
  end

  @tag :seatbelt
  test "ledger acceptance runner resolves Elixir through mise in the sandbox", %{
    tmp_dir: tmp_dir
  } do
    repo = Git.create!(Path.join(tmp_dir, "mise-ledger-project"))
    test_dir = Path.join([repo, "test", "acceptance"])
    File.mkdir_p!(test_dir)
    File.write!(Path.join(repo, ".gitignore"), "_build/\ndeps/\n")
    File.write!(Path.join(repo, "mix.exs"), mix_project())
    File.write!(Path.join([repo, "test", "test_helper.exs"]), "ExUnit.start()\n")
    File.write!(Path.join(test_dir, "slug_test.exs"), acceptance_test())
    Git.git!(repo, ["add", "--all"])
    Git.git!(repo, ["commit", "--quiet", "-m", "seed mise acceptance fixture"])

    run_dir = Path.join(tmp_dir, "mise-ledger-run")
    home = Path.join(tmp_dir, "home")
    mix_home = Path.join(tmp_dir, "mix-home")
    File.mkdir_p!(home)
    File.mkdir_p!(mix_home)

    mise = System.find_executable("mise")
    elixir = System.find_executable("elixir")
    assert is_binary(mise)
    assert is_binary(elixir)

    config_file = Path.expand("../../mise.toml", __DIR__)

    data_dir =
      elixir
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()

    env = %{
      "HOME" => home,
      "PATH" =>
        Enum.join(
          [
            Path.dirname(mise),
            "/opt/bench/mise/installs/elixir/1.20.2-otp-29/bin",
            "/opt/bench/mise/installs/erlang/29.0.3/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
          ],
          ":"
        ),
      "TMPDIR" => tmp_dir,
      "MISE_CONFIG_FILE" => config_file,
      "MISE_DATA_DIR" => data_dir,
      "MISE_TRUSTED_CONFIG_PATHS" => Enum.join([repo, Path.dirname(config_file)], ":"),
      "MISE_STATE_DIR" => Path.join(run_dir, "mise-state"),
      "MISE_CACHE_DIR" => Path.join(run_dir, "mise-cache"),
      "MIX_ENV" => "test",
      "MIX_HOME" => mix_home
    }

    sandbox = %Sandbox{
      enabled: true,
      home: home,
      project_root: repo,
      origin: repo,
      workspace: repo,
      run_dir: run_dir,
      tmp_dir: tmp_dir,
      workspace_is_project: true
    }

    assert {:ok, %{status: :pass, ledger: [%{tag: "slug/A1", status: :passed}]}} =
             Checks.acceptance(repo, acceptance_intent(), run_dir, env, Git.env(), sandbox)
  end

  defp acceptance_intent do
    %Intent{
      slug: "slug",
      title: "Mise acceptance",
      size: :small,
      brief: "Run the acceptance suite through mise.",
      acceptance: [
        %AcceptanceItem{id: "A1", text: "The test loads.", verify: :test, domain: nil}
      ],
      domains: [],
      notes: nil,
      path: ".kogen/intents/slug/intent.md",
      sha256: "fixture"
    }
  end

  defp mix_project do
    """
    defmodule MiseLedger.MixProject do
      use Mix.Project
      def project, do: [app: :mise_ledger, version: "0.1.0", elixir: "~> 1.20"]
    end
    """
  end

  defp acceptance_test do
    """
    defmodule MiseLedger.AcceptanceTest do
      use ExUnit.Case, async: true
      @tag intent: "slug/A1"
      test "loads through mise", do: assert(true)
    end
    """
  end
end
