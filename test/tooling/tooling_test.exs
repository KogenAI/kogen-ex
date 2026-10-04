defmodule Kogen.Tooling.ToolsTest do
  use Kogen.Testkit.Case

  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ToolCall
  alias Kogen.Tooling.Codec
  alias Kogen.Tooling.Context
  alias Kogen.Tooling.ToolArgs
  alias Kogen.Tooling.ToolResult
  alias Kogen.Tooling.Tools

  test "schemas and decoded calls share the Builder tool contract" do
    assert Codec.tool_names(:developer) == [:read, :search, :edit, :write, :shell]
    assert Enum.map(Codec.tool_specs([:read, :shell]), & &1["name"]) == ["read", "shell"]

    assert {:ok, %ToolArgs{name: "read", path: "README.md", offset: 3, limit: nil}} =
             Codec.decode_tool_call(%ToolCall{
               id: "read-1",
               name: "read",
               arguments: %{"path" => "README.md", "offset" => 3}
             })

    assert {:error, :invalid_arguments} =
             Codec.decode_tool_call(%ToolCall{id: "bad", name: "shell", arguments: %{}})
  end

  test "reads only from the worktree and rejects path escapes", %{tmp_dir: tmp_dir} do
    workdir = Path.join(tmp_dir, "candidate")
    run_dir = Path.join(tmp_dir, "run")
    File.mkdir_p!(workdir)
    File.write!(Path.join(workdir, "README.md"), "inside\n")
    File.write!(Path.join(tmp_dir, "secret.txt"), "outside secret\n")
    context = context(workdir, run_dir)

    assert %ToolResult{output: output, paths: ["README.md"], is_error: false} =
             Tools.run(context, call("read", %{"path" => "README.md"}), [:read])

    assert output =~ "1: inside"

    assert %ToolResult{output: error, is_error: true} =
             Tools.run(context, call("read", %{"path" => "../secret.txt"}), [:read])

    assert error =~ "Path escapes the worktree"
    refute error =~ "outside secret"
  end

  defp context(workdir, run_dir) do
    %Context{
      workdir: workdir,
      run_dir: run_dir,
      project: %Project{
        root: workdir,
        name: "fixture",
        checks: [],
        setup: [],
        fix: [],
        diagnose: [],
        protected_paths: [],
        domains: %{}
      },
      proc_mod: Kogen.Proc
    }
  end

  defp call(name, arguments), do: %ToolCall{id: "#{name}-test", name: name, arguments: arguments}
end
