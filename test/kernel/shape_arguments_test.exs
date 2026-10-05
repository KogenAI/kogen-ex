defmodule Kogen.Kernel.ShapeArgumentsTest do
  use ExUnit.Case, async: true

  alias Kogen.Cli.Args
  alias Kogen.Cli.Arguments
  alias Kogen.Kernel.CLI.TaskInput

  test "intent shape accepts a task file and output format" do
    assert {:ok, %Args{} = args} =
             Arguments.parse([
               "intent",
               "shape",
               "new-feature",
               "--task-file",
               "/tmp/task.md",
               "--project",
               "/tmp/project",
               "--json"
             ])

    assert args.command == :intent_shape
    assert args.task_file == "/tmp/task.md"
    assert args.json
  end

  test "intent shape reads from stdin when its task file is omitted or -" do
    assert {:ok, %Args{command: :intent_shape, task_file: nil}} =
             Arguments.parse(["intent", "shape", "new-feature"])

    assert {:ok, %Args{command: :intent_shape, task_file: "-"}} =
             Arguments.parse(["intent", "shape", "new-feature", "--task-file", "-"])
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
