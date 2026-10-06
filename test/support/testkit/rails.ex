defmodule Kogen.Testkit.Rails do
  @moduledoc "Offline Rails fixture using the local Ruby toolchain and vendored gem archives."

  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Proc

  @fixture Path.expand("../../../fixtures/rails_app", __DIR__)

  def unavailable_reason do
    case ruby_path() do
      {:ok, _path} -> false
      {:error, reason} -> reason
    end
  end

  def environment!(project, home, profile) do
    {:ok, env} = Kogen.Kernel.candidate_environment(project, runtime!(project, home), profile)
    env
  end

  def runtime!(project, home) do
    {:ok, runtime} = Kogen.Kernel.runtime()
    {:ok, ruby} = ruby_path()
    toolchain_home = runtime.base_env["HOME"]
    runtime_tmp = Path.join(Path.dirname(project), "runtime-tmp")
    File.mkdir_p!(runtime_tmp)

    env =
      runtime.base_env
      |> Map.merge(Git.env())
      |> Map.merge(%{
        "HOME" => home,
        "PATH" => Path.join(ruby, "bin") <> ":" <> runtime.base_env["PATH"],
        "MISE_DATA_DIR" => Path.join(toolchain_home, ".local/share/mise"),
        "TMPDIR" => runtime_tmp
      })

    mise = Path.join(project, ".test-bin/mise")
    File.mkdir_p!(Path.dirname(mise))
    toolchain = Map.take(env, ["PATH"])
    json = toolchain |> :json.encode() |> IO.iodata_to_binary()
    quoted = "'" <> String.replace(json, "'", "'\\''") <> "'"
    File.write!(mise, "#!/bin/sh\n[ \"$1\" = env ] || exit 64\nprintf '%s\\n' " <> quoted <> "\n")
    File.chmod!(mise, 0o755)

    %{
      runtime
      | base_env: Map.put(env, "MISE_TRUSTED_CONFIG_PATHS", project),
        git_env: Git.env(),
        mise: mise
    }
  end

  def project!(root) do
    File.mkdir_p!(root)

    for path <- Path.wildcard(Path.join(@fixture, "**/*"), match_dot: true),
        File.regular?(path),
        relative = Path.relative_to(path, @fixture),
        not String.starts_with?(relative, [
          "vendor/bundle/",
          ".bundle/",
          ".bundle-user/",
          "tmp/",
          "log/"
        ]),
        relative != "ledger-check.jsonl" do
      target = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(path, target)
    end

    File.chmod!(Path.join(root, "bin/rails"), 0o755)
    File.mkdir_p!(Path.join(root, ".kogen"))

    File.write!(
      Path.join(root, ".kogen/project.yaml"),
      "name: tiny_rails\ndomains:\n  app: [app, test]\n"
    )

    File.write!(Path.join(root, ".mise.toml"), "[tools]\nruby = \"3.4.8\"\n")

    File.write!(
      Path.join(root, ".gitignore"),
      File.read!(Path.join(root, ".gitignore")) <> "deps/\n_build/\n.test-bin/\n"
    )

    Git.git!(root, ["init", "--quiet", "--template="])
    Git.git!(root, ["add", "--all"])
    Git.git!(root, ["commit", "--quiet", "-m", "Seed offline Rails application"])
    Git.git!(root, ["branch", "-M", "main"])
    root
  end

  defp ruby_path do
    {:ok, runtime} = Kogen.Kernel.runtime()
    options = [cd: @fixture, env: Map.to_list(runtime.base_env)]

    with {path, 0} <- Proc.cmd(runtime.mise, ["where", "ruby", "3.4.8"], options),
         path = String.trim(path),
         ruby = Path.join(path, "bin/ruby"),
         true <- File.regular?(ruby),
         {platform, 0} <- Proc.cmd(ruby, ["-e", "puts RUBY_PLATFORM"], options),
         true <- String.contains?(platform, "arm64-darwin") do
      {:ok, path}
    else
      _unavailable -> unavailable()
    end
  end

  defp unavailable,
    do:
      {:error,
       "Offline Rails fixture requires installed Ruby 3.4.8 on arm64-darwin; no runtime or gems are downloaded."}
end
