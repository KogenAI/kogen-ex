defmodule Kogen.Harness.ShellPlanner do
  @moduledoc false

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProcResult
  alias Kogen.Conversation.PlanPolicy
  alias Kogen.Conversation.PlanShellPrompts
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Exchange.Request
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Plan
  alias Kogen.Harness.Usage
  alias Kogen.Tooling.Error

  @max_turns 3
  @file_list_timeout_ms 120_000
  @request_timeout_ms 900_000

  def run(%Opts{} = opts, intent_text) when opts.plan_max_words in 300..2000 do
    with {:ok, files} <- repository_file_list(opts.run_dir, opts.proc_mod, opts.workdir, opts.env) do
      {model, effort} = Map.get(opts.models, :planner, opts.models.strong)

      request = %Request{
        stage: :plan,
        turn: 1,
        model: model,
        effort: effort,
        instructions:
          PlanShellPrompts.planner_system(opts.planner_difficulty, opts.plan_max_words),
        items: [Codec.user_item(PlanShellPrompts.planner_input(intent_text, files))],
        tool_names: [],
        remaining_ms: opts.limits.wall_ms,
        measurements: PlanShellPrompts.measurements(intent_text, opts.plan_max_words)
      }

      deadline =
        System.monotonic_time(:millisecond) + min(opts.limits.wall_ms, @request_timeout_ms)

      plan_turn(opts, request, deadline, Usage.zero())
    end
  end

  def run(_opts, _intent_text),
    do: error(:invalid_plan_budget, "plan_max_words must be an integer from 300 to 2000.")

  defp plan_turn(opts, request, deadline, total) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    request = %{request | remaining_ms: min(remaining, @request_timeout_ms)}

    if remaining == 0 do
      error(:plan_timeout, "Planner wall deadline reached while shortening its plan.")
    else
      case Exchange.respond(opts, request) do
        {:ok, %ModelResponse{tool_calls: []} = response} ->
          accept_or_shorten(opts, request, deadline, Codec.usage(total, response.usage), response)

        {:ok, %ModelResponse{}} ->
          error(:plan_tools_not_allowed, "The ls-files planner returned a tool call.")

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp accept_or_shorten(opts, request, deadline, total, response) do
    if PlanPolicy.within_budget?(response.text, request.measurements) do
      {:ok,
       %Plan{
         text: response.text,
         usage: Usage.to_map(total),
         builder_addendum: PlanShellPrompts.builder_addendum(response.text),
         measurements: request.measurements
       }}
    else
      shorten(opts, request, deadline, total, response)
    end
  end

  defp shorten(_opts, %{turn: @max_turns}, _deadline, _total, _response),
    do:
      error(
        :plan_word_budget_exceeded,
        "Planner exceeded the configured hand-off word budget after three responses; no plan was injected."
      )

  defp shorten(opts, request, deadline, total, response) do
    note =
      "The hand-off exceeds its #{request.measurements.plan_max_words}-word budget. Shorten to at most #{request.measurements.plan_max_words - request.measurements.plan_wrapper_words} response words, keeping 3–6 concise steps, risks/API checks, and one targeted verification strategy. Reference the Intent's obligations instead of repeating them."

    request = %{
      request
      | turn: request.turn + 1,
        items: request.items ++ response.raw_items ++ [Codec.user_item(note)]
    }

    plan_turn(opts, request, deadline, total)
  end

  defp repository_file_list(run_dir, proc_mod, workdir, env) do
    log_dir = Path.join(run_dir, "logs")

    log_path =
      Path.join(
        log_dir,
        "plan-shell-ls-files-#{System.unique_integer([:positive, :monotonic])}.log"
      )

    with :ok <- File.mkdir_p(log_dir),
         {:ok, %ProcResult{exit_status: 0, timed_out: false, log_path: output_path}}
         when is_binary(output_path) <-
           proc_mod.run(["git", "ls-files"],
             cd: workdir,
             env: env,
             timeout_ms: @file_list_timeout_ms,
             log_path: log_path
           ),
         {:ok, files} <- File.read(output_path) do
      {:ok, files}
    else
      {:error, reason} -> file_list_failure({:error, reason})
      {:ok, %ProcResult{} = result} -> file_list_failure({:ok, result})
    end
  end

  defp file_list_failure({:ok, %ProcResult{timed_out: true}}),
    do: error(:plan_file_list_timeout, "git ls-files exceeded its 120-second timeout.")

  defp file_list_failure({:ok, %ProcResult{exit_status: status}}),
    do: error(:plan_file_list_failed, "git ls-files exited with status #{inspect(status)}.")

  defp file_list_failure({:error, %Error{} = reason}), do: {:error, reason}

  defp file_list_failure({:error, reason}),
    do: error(:plan_file_list_failed, "Could not read git ls-files output: #{inspect(reason)}.")

  defp error(reason, detail), do: {:error, %Error{reason: reason, detail: detail}}
end
