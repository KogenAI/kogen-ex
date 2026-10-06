defmodule Kogen.Tooling.OutputBudgetTest do
  use Kogen.Testkit.Case, async: true

  alias Kogen.Contracts.Project
  alias Kogen.Contracts.ToolCall
  alias Kogen.Tooling.Context
  alias Kogen.Tooling.ShaperTools
  alias Kogen.Tooling.Tools

  test "large file lists preserve their start and end and can be retrieved without rerunning", %{
    tmp_dir: tmp
  } do
    opts = opts(tmp)

    cmd =
      ~s{i=1; while [ "$i" -le 6000 ]; do printf 'file-%04d.ex\\n' "$i"; i=$((i+1)); done; printf ran > marker}

    result = run(opts, "shell", %{"cmd" => cmd, "tool_result_tokens" => 128})
    assert result.is_error == false
    assert result.output =~ "file-0001.ex"
    assert result.output =~ "file-6000.ex"
    assert result.output =~ "truncated"
    assert result.output =~ "tool_output"
    assert byte_size(result.output) <= 512
    assert result.receipt.truncated

    full =
      File.read!(Path.join([opts.run_dir, "logs", "tool-result-#{result.receipt.handle}.log"]))

    assert byte_size(full) > 70_000
    File.rm!(Path.join(opts.workdir, "marker"))

    retrieved =
      run(opts, "tool_output", %{
        "handle" => result.receipt.handle,
        "output_offset" => 1000,
        "output_limit" => 200,
        "tool_result_tokens" => 128
      })

    assert retrieved.is_error == false
    assert retrieved.output =~ binary_part(full, 1000, 200)
    refute File.exists?(Path.join(opts.workdir, "marker"))
    assert [first, second] = receipts(opts)
    assert first["tool_result_tokens"] == 128
    assert first["original_bytes"] > first["returned_bytes"]
    assert second["output_offset"] == 1000
    assert second["output_limit"] == 200
  end

  test "tool budgets never truncate a generation-heavy file write", %{tmp_dir: tmp} do
    opts = opts(tmp)
    content = String.duplicate("complete generated content\n", 3000)

    result =
      run(opts, "write", %{
        "path" => "patch.txt",
        "content" => content,
        "tool_result_tokens" => 128
      })

    refute result.is_error
    assert File.read!(Path.join(opts.workdir, "patch.txt")) == content
    assert result.receipt.tool_result_tokens == 128
    assert byte_size(result.output) <= 512
  end

  test "invalid result budgets fail before executing a mutation", %{tmp_dir: tmp} do
    opts = opts(tmp)

    for value <- [0, -1, "2000", 100_001] do
      result = run(opts, "shell", %{"cmd" => "touch forbidden", "tool_result_tokens" => value})
      assert result.is_error
      assert result.output =~ "arguments or output budgets"
    end

    refute File.exists?(Path.join(opts.workdir, "forbidden"))
  end

  test "scoped shaper writes honor result ranges without shortening their files", %{tmp_dir: tmp} do
    opts = opts(tmp)
    path = ".kogen/intents/budget/intent.md"
    content = String.duplicate("complete generated content\n", 3000)

    call = %ToolCall{
      id: "call-shaper-write",
      name: "write",
      arguments: %{
        "path" => path,
        "content" => content,
        "tool_result_tokens" => 128,
        "output_offset" => 6,
        "output_limit" => 6
      }
    }

    result = ShaperTools.run(opts, call, [path])
    refute result.is_error
    assert File.read!(Path.join(opts.workdir, path)) == content
    assert result.output =~ ".kogen"
    assert result.output =~ "truncated/range"
    assert result.receipt.ranges == [[6, 12]]
    assert [receipt] = receipts(opts)
    assert receipt["tool_result_tokens"] == 128
    assert receipt["output_offset"] == 6
    assert receipt["output_limit"] == 6
  end

  test "UTF-8 result ranges preserve codepoints and byte budgets", %{tmp_dir: tmp} do
    opts = opts(tmp)
    File.write!(Path.join(opts.workdir, "unicode.txt"), String.duplicate("🦊é", 3000))
    result = run(opts, "read", %{"path" => "unicode.txt", "tool_result_tokens" => 128})
    assert String.valid?(result.output)
    assert byte_size(result.output) <= 512

    range =
      run(opts, "tool_output", %{
        "handle" => result.receipt.handle,
        "output_offset" => 20,
        "output_limit" => 101,
        "tool_result_tokens" => 128
      })

    refute range.is_error
    assert String.valid?(range.output)
    assert byte_size(range.output) <= 512
  end

  test "range handles cannot escape run logs through names or symlinks", %{tmp_dir: tmp} do
    opts = opts(tmp)
    outside = Path.join(tmp, "outside.txt")
    File.write!(outside, "outside data")
    File.mkdir_p!(Path.join(opts.run_dir, "logs"))
    handle = String.duplicate("a", 64)
    File.ln_s!(outside, Path.join([opts.run_dir, "logs", "tool-result-#{handle}.log"]))

    for requested <- [handle, "../../outside.txt"] do
      result = run(opts, "tool_output", %{"handle" => requested})
      assert result.is_error
      refute result.output =~ "outside data"
    end
  end

  test "project defaults and per-call overrides leave distinct tool receipts", %{tmp_dir: tmp} do
    opts = opts(tmp)

    opts = %{
      opts
      | project: %{
          opts.project
          | build: %{tool_result_tokens: 256, model_generation_tokens: 12_000}
        }
    }

    default = run(opts, "shell", %{"cmd" => "printf tiny"})
    override = run(opts, "shell", %{"cmd" => "printf tiny", "tool_result_tokens" => 128})
    assert default.receipt.tool_result_tokens == 256
    assert override.receipt.tool_result_tokens == 128
    assert [first, second] = receipts(opts)
    refute Map.has_key?(first, "model_generation_tokens")
    assert first["requested_tool_result_tokens"] == :null
    assert second["requested_tool_result_tokens"] == 128
  end

  test "search retains matches beyond the old fixed result count", %{tmp_dir: tmp} do
    opts = opts(tmp)
    File.write!(Path.join(opts.workdir, "matches.txt"), String.duplicate("needle\n", 3000))

    result =
      run(opts, "search", %{
        "pattern" => "needle",
        "path" => "matches.txt",
        "tool_result_tokens" => 128
      })

    refute result.is_error
    assert result.output =~ "matches.txt:1:needle"
    assert result.output =~ "matches.txt:3000:needle"
    assert result.receipt.truncated
    assert result.output =~ "tool_output"
    assert byte_size(result.output) <= 512
  end

  test "binary command results keep their exit status and complete base64 data", %{tmp_dir: tmp} do
    result = run(opts(tmp), "shell", %{"cmd" => "printf '\\377'", "tool_result_tokens" => 128})
    refute result.is_error
    assert result.output =~ "exit 0"
    assert result.output =~ "base64 encoded"
    assert result.output =~ "/w=="
  end

  defp run(opts, name, arguments),
    do:
      Tools.run(opts, %ToolCall{id: "call-#{name}", name: name, arguments: arguments}, [
        :read,
        :search,
        :write,
        :shell,
        :tool_output
      ])

  defp receipts(opts),
    do:
      opts.run_dir
      |> Path.join("requests.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&:json.decode/1)

  defp opts(tmp) do
    workdir = Path.join(tmp, "candidate")
    File.mkdir_p!(workdir)

    %Context{
      workdir: workdir,
      run_dir: Path.join(tmp, "run"),
      proc_mod: Kogen.Proc,
      project: %Project{
        root: workdir,
        name: "budget",
        setup: [],
        checks: [],
        fix: [],
        diagnose: [],
        protected_paths: [],
        domains: %{}
      }
    }
  end
end
