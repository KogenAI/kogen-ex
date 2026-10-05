defmodule Kogen.Kernel.ShapeArgumentsTest do
  use ExUnit.Case, async: true

  alias Kogen.Cli.Args
  alias Kogen.Cli.Arguments
  alias Kogen.Kernel.CLI.TaskInput

  test "intent shape takes the request file as an argument, - for stdin" do
    assert {:ok, %Args{} = args} =
             Arguments.parse([
               "intent",
               "shape",
               "new-feature",
               "/tmp/task.md",
               "--project",
               "/tmp/project",
               "--json"
             ])

    assert {args.command, args.positionals, args.json} ==
             {:intent_shape, ["new-feature", "/tmp/task.md"], true}

    assert {:ok, %Args{positionals: ["new-feature", "-"]}} =
             Arguments.parse(["intent", "shape", "new-feature", "-"])
  end

  test "task input reads stdin and rejects empty input" do
    assert {:ok, {:ok, "Add a widget\n"}} =
             StringIO.open("Add a widget\n", fn stdin ->
               TaskInput.read(nil, stdin)
             end)

    assert {:ok, {:ok, "Fix a bug\n"}} =
             StringIO.open("Fix a bug\n", fn stdin ->
               TaskInput.read("-", stdin)
             end)

    assert {:ok, {:error, {:task_input_unavailable, "stdin", :empty}}} =
             StringIO.open("  \n", fn stdin -> TaskInput.read(nil, stdin) end)
  end
end
