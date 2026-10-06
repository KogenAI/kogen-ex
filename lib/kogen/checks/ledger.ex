defmodule Kogen.Checks.Ledger do
  @moduledoc false

  alias Kogen.Checks.Ledger.ElixirRunner
  alias Kogen.Checks.Ledger.Rails
  alias Kogen.Checks.Ledger.Report
  alias Kogen.Checks.Ledger.Validation
  alias Kogen.Checks.LedgerRow
  alias Kogen.Checks.Timing
  alias Kogen.Contracts.CommandExit
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.MiseEnvironment
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Stack
  alias Kogen.Proc
  alias Kogen.Proc.Sandbox
  alias Kogen.Workspace

  @spec acceptance(Path.t(), Intent.t(), Path.t()) ::
          {:ok, Kogen.Checks.acceptance_result()}
          | {:error, Failure.t()}
  def acceptance(workdir, intent, run_dir), do: acceptance(workdir, intent, run_dir, %{}, %{})

  @spec acceptance(
          Path.t(),
          Intent.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()}
        ) ::
          {:ok, Kogen.Checks.acceptance_result()}
          | {:error, Failure.t()}
  def acceptance(workdir, %Intent{} = intent, run_dir, env, git_env) do
    acceptance(workdir, intent, run_dir, env, git_env, nil)
  end

  @spec acceptance(
          Path.t(),
          Intent.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()},
          Sandbox.t() | nil
        ) ::
          {:ok, Kogen.Checks.acceptance_result()}
          | {:error, Failure.t()}
  def acceptance(workdir, %Intent{} = intent, run_dir, env, git_env, sandbox) do
    with {:ok, items} <- test_items(intent),
         {:ok, before_tree} <- Workspace.tree_hash(workdir, git_env) do
      result = report(workdir, intent, run_dir, env, sandbox)

      with {:ok, after_tree} <- Workspace.tree_hash(workdir, git_env),
           :ok <- same_tree(before_tree, after_tree),
           {:ok, rows, exit_status} <- result do
        failures = Validation.candidate(items, rows, exit_status, intent.slug)
        status = if failures == [], do: :pass, else: {:fail, failures}
        {:ok, %{status: status, ledger: rows, timing: Timing.latest(run_dir)}}
      end
    else
      {:error, %Failure{} = failure} -> {:error, failure}
      {:error, reason} -> {:error, failure(:controller, :workspace_failed, inspect(reason))}
    end
  end

  @spec red_on_base(Path.t(), Intent.t(), Path.t()) :: :ok | {:error, Failure.t()}
  def red_on_base(workdir, intent, run_dir), do: red_on_base(workdir, intent, run_dir, %{}, %{})

  @spec red_on_base(
          Path.t(),
          Intent.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()}
        ) :: :ok | {:error, Failure.t()}
  def red_on_base(workdir, %Intent{} = intent, run_dir, env, git_env) do
    red_on_base(workdir, intent, run_dir, env, git_env, nil)
  end

  @spec red_on_base(
          Path.t(),
          Intent.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()},
          Sandbox.t() | nil
        ) :: :ok | {:error, Failure.t()}
  def red_on_base(workdir, %Intent{} = intent, run_dir, env, git_env, sandbox) do
    with {:ok, rows} <- base_rows(workdir, intent, run_dir, env, git_env, sandbox) do
      validate_base(intent, rows, run_dir)
    end
  end

  @spec base_rows(
          Path.t(),
          Intent.t(),
          Path.t(),
          %{String.t() => String.t()},
          %{String.t() => String.t()},
          Sandbox.t() | nil
        ) :: {:ok, [LedgerRow.t()]} | {:error, Failure.t()}
  def base_rows(workdir, %Intent{} = intent, run_dir, env, git_env, sandbox) do
    with {:ok, _items} <- test_items(intent),
         {:ok, before_tree} <- Workspace.tree_hash(workdir, git_env) do
      result = report(workdir, intent, run_dir, env, sandbox)

      with {:ok, after_tree} <- Workspace.tree_hash(workdir, git_env),
           :ok <- same_tree(before_tree, after_tree),
           {:ok, rows, _exit_status} <- result do
        {:ok, rows}
      end
    end
  end

  @spec validate_base(Intent.t(), [LedgerRow.t()], Path.t()) :: :ok | {:error, Failure.t()}
  def validate_base(%Intent{} = intent, rows, run_dir) do
    with {:ok, items} <- test_items(intent) do
      case Validation.base(items, rows, intent.slug) do
        :ok ->
          :ok

        {:error, %Failure{} = failure} ->
          {:error, base_feedback(failure, rows, intent.slug, run_dir)}
      end
    end
  end

  defp base_feedback(%Failure{} = failure, rows, slug, run_dir) do
    row = Enum.find(rows, &(&1.tag != "" and String.contains?(failure.detail, &1.tag)))
    output = first_output_lines(Path.join([run_dir, "logs", "acceptance.log"]))

    missing_tag =
      if failure.reason == :acceptance_missing_on_base,
        do: "no tests tagged intent: #{failure.detail}\n",
        else: ""

    context =
      if row do
        "Acceptance test: #{row.test} [#{row.tag}]\n"
      else
        rows
        |> Enum.filter(&String.starts_with?(&1.tag, slug <> "/"))
        |> Enum.map_join("", &"Acceptance test: #{&1.test} [#{&1.tag}]\n")
      end

    %{
      failure
      | detail:
          failure.detail <>
            "\n" <> missing_tag <> context <> "Output (first 20 lines):\n" <> output
    }
  end

  defp first_output_lines(path) do
    case File.read(path) do
      {:ok, contents} ->
        output = contents |> String.split("\n", trim: false) |> Enum.take(20) |> Enum.join("\n")
        if String.trim(output) == "", do: "(no output captured)", else: output

      {:error, _reason} ->
        "(acceptance output log unavailable)"
    end
  end

  defp report(workdir, %Intent{} = intent, run_dir, env, sandbox) do
    test_path = Path.join(workdir, Stack.acceptance_test(workdir, intent.slug))

    with :ok <- prepared_test(test_path),
         :ok <- prepare_run_files(run_dir),
         {:ok, exit_status} <-
           run_tests(
             workdir,
             test_path,
             run_dir,
             runner_environment(workdir, env, run_dir, intent.slug),
             sandbox
           ) do
      if CommandExit.tool_missing?(exit_status) do
        tool_missing_failure(run_dir, exit_status)
      else
        case read_report(Path.join(run_dir, "ledger.jsonl")) do
          {:ok, rows} ->
            {:ok, rows, exit_status}

          {:error, %Failure{reason: :ledger_empty}} ->
            empty_report_failure(intent, run_dir, exit_status)

          {:error, %Failure{} = failure} ->
            {:error, failure}
        end
      end
    end
  end

  defp empty_report_failure(%Intent{} = intent, run_dir, exit_status) do
    output = acceptance_output(Path.join([run_dir, "logs", "acceptance.log"]))

    case missing_runtime_tool(output) do
      tool when is_binary(tool) ->
        {:error,
         failure(
           :environment,
           :tool_missing,
           "Acceptance test runner could not find #{tool}.\nOutput (first 20 lines):\n#{output}"
         )}

      nil when exit_status != 0 ->
        {:error,
         failure(
           :candidate,
           :acceptance_compile_failed,
           "Acceptance test file failed to compile or load (exit status #{exit_status}).\n" <>
             "Output (first 20 lines):\n#{output}"
         )}

      nil ->
        tags =
          intent.acceptance
          |> Enum.filter(&(&1.verify in [:test, :test_keep]))
          |> Enum.map_join("\n", &"no tests tagged intent: #{intent.slug}/#{&1.id}")

        {:error, failure(:candidate, :no_tagged_tests, tags)}
    end
  end

  defp tool_missing_failure(run_dir, exit_status) do
    output = acceptance_output(Path.join([run_dir, "logs", "acceptance.log"]))
    tool = missing_runtime_tool(output) || "a required tool"

    detail =
      "Acceptance test runner could not find #{tool} (exit #{exit_status}).\n" <>
        "Output (first 20 lines):\n#{output}"

    {:error, failure(:environment, :tool_missing, detail)}
  end

  defp missing_runtime_tool(output) do
    lowered = String.downcase(output)

    cond do
      String.contains?(lowered, "erl: not found") or
          String.contains?(lowered, "could not find erl") ->
        "erl"

      String.contains?(lowered, "elixir: no such file or directory") ->
        "elixir"

      String.contains?(lowered, "mix: not found") or
        String.contains?(lowered, "mix command not found") or
          String.contains?(lowered, "could not execute \"mix\"") ->
        "mix"

      true ->
        nil
    end
  end

  defp acceptance_output(path) do
    case File.read(path) do
      {:ok, contents} ->
        output = contents |> String.split("\n", trim: false) |> Enum.take(20) |> Enum.join("\n")
        if String.trim(output) == "", do: "(no output captured)", else: output

      {:error, _reason} ->
        "(acceptance output log unavailable)"
    end
  end

  defp prepared_test(path) do
    if File.regular?(path),
      do: :ok,
      else:
        {:error,
         failure(:environment, :tests_not_prepared, "approved acceptance test is missing")}
  end

  defp prepare_run_files(run_dir) do
    if Path.type(run_dir) == :absolute do
      with :ok <- File.mkdir_p(Path.join(run_dir, "logs")),
           :ok <- ElixirRunner.prepare(run_dir),
           :ok <- Rails.prepare(run_dir),
           :ok <- File.write(Path.join(run_dir, "ledger.jsonl"), "") do
        :ok
      else
        {:error, reason} -> {:error, failure(:environment, :ledger_setup, inspect(reason))}
      end
    else
      {:error, failure(:controller, :invalid_run_dir, "run directory must be absolute")}
    end
  end

  defp run_tests(workdir, test_path, run_dir, env, sandbox) do
    report_path = Path.join(run_dir, "ledger.jsonl")
    log_path = Path.join([run_dir, "logs", "acceptance.log"])

    options = [
      cd: workdir,
      env: Map.put(env, "KOGEN_LEDGER_REPORT", report_path),
      log_path: log_path,
      sandbox: sandbox
    ]

    workdir
    |> test_argv(test_path, run_dir, env)
    |> Proc.run(options)
    |> Timing.process(run_dir, "acceptance", ["mix", "test"])
    |> process_result()
  end

  defp runner_environment(workdir, env, run_dir, slug) do
    if Stack.detect(workdir) == :rails, do: Rails.environment(env, run_dir, slug), else: env
  end

  defp test_argv(workdir, test_path, run_dir, env) do
    argv =
      case Stack.detect(workdir) do
        :rails -> ["bundle", "exec", "rails", "test", Path.relative_to(test_path, workdir)]
        :elixir -> ElixirRunner.argv(workdir, test_path, run_dir)
      end

    if MiseEnvironment.configured?(env), do: ["mise", "exec", "--" | argv], else: argv
  end

  defp process_result(result) do
    case result do
      {:ok, %ProcResult{exit_status: status, timed_out: false}}
      when is_integer(status) ->
        {:ok, status}

      {:ok, %ProcResult{timed_out: true}} ->
        {:error, failure(:candidate, :acceptance_timeout, "acceptance tests timed out")}

      {:ok, %ProcResult{exit_status: nil}} ->
        {:error,
         failure(:environment, :missing_exit_status, "acceptance runner returned no exit status")}

      {:error, :enoent} ->
        {:error, failure(:environment, :tool_missing, "Acceptance test runner is not available")}

      {:error, reason} ->
        {:error, failure(:environment, :process_failed, inspect(reason))}
    end
  end

  defp read_report(path) do
    case Report.read(path) do
      {:ok, rows} -> {:ok, rows}
      {:error, failure} -> {:error, failure}
    end
  end

  defp test_items(%Intent{acceptance: acceptance}) do
    items = Enum.filter(acceptance, &(&1.verify in [:test, :test_keep]))

    cond do
      items == [] ->
        {:error,
         failure(:environment, :no_test_acceptance, "Intent has no test acceptance items")}

      length(items) != length(acceptance) ->
        {:error,
         failure(
           :environment,
           :unsupported_acceptance_kind,
           "only test and test_keep acceptance items are supported"
         )}

      true ->
        {:ok, items}
    end
  end

  defp same_tree(tree, tree), do: :ok

  defp same_tree(_before, _after),
    do:
      {:error, failure(:candidate, :tree_mutated, "acceptance tests changed the candidate tree")}

  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end
