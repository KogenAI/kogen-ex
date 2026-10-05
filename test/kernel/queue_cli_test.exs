defmodule Kogen.Kernel.QueueCLITest do
  use Kogen.Testkit.Case

  alias Kogen.Testkit.Git
  alias Kogen.Testkit.Proc

  @fixture Path.expand("../../fixtures/hello_app", __DIR__)

  test "queue start with nothing approved returns at once and releases its lock", %{
    tmp_dir: tmp_dir
  } do
    project = Git.create!(Path.join(tmp_dir, "project"))
    File.mkdir_p!(Path.join(project, ".kogen"))

    File.cp!(
      Path.join(@fixture, ".kogen/project.yaml"),
      Path.join(project, ".kogen/project.yaml")
    )

    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)

    assert cli(["queue", "start"], project, home) == "queue: nothing to build\n"
    assert cli(["status"], project, home) == "Queue: stopped\nNo Intents.\n"
    assert Path.wildcard(Path.join(home, ".kogen/workspaces/*/queue.pid")) == []
  end

  defp cli(args, cd, home) do
    script = "Kogen.Kernel.CLI.main(#{inspect(args)})"
    Proc.cmd!("elixir", child_args() ++ ["-e", script], cd: cd, env: [{"HOME", home}])
  end

  defp child_args do
    Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)
  end
end
