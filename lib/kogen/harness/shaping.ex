defmodule Kogen.Harness.Shaping.State do
  @moduledoc false

  @enforce_keys [:opts, :slug, :transcript_path, :items, :calls, :turns, :turn_offset, :deadline]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          opts: Kogen.Harness.Opts.t(),
          slug: String.t(),
          transcript_path: Path.t(),
          items: [map()],
          calls: [Kogen.Harness.ShapeCall.t()],
          turns: non_neg_integer(),
          turn_offset: non_neg_integer(),
          deadline: integer()
        }
end

defmodule Kogen.Harness.Shaping do
  @moduledoc false

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Exchange.Request, as: ExchangeRequest
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Recording
  alias Kogen.Harness.ShapeCall
  alias Kogen.Harness.ShapePass
  alias Kogen.Harness.ShaperTools
  alias Kogen.Harness.Shaping.State
  alias Kogen.Harness.Usage
  alias Kogen.Tooling.Error
  alias Kogen.Tooling.ToolResult

  @instructions """
  You are Kogen Intent shaper. Read the project and task, then shape a short, actionable Intent and its acceptance test. Do not implement the task.

  Write exactly these two files, replacing `<slug>` with the requested slug:
  - `.kogen/intents/<slug>/intent.md`
  - `.kogen/acceptance/<slug>_test.exs`

  Use this exact Intent structure. Replace every placeholder with real content; do not add a `## Brief` heading.

  ```markdown
  ---
  title: <plain title, at most 72 characters>
  domains: [<one or more configured domain names>]
  size: medium
  ---
  <one concise prose paragraph describing the problem, scope, and behavior to preserve>

  ## Acceptance
  - A1: <one observable, testable outcome in at most 25 words>
  - A2: <one observable, testable outcome in at most 25 words>

  ## Verify
  - A1: test domain=<configured-domain>
  - A2: test keep domain=<configured-domain>

  ## Notes
  Approach: <name the relevant code path and concrete implementation mechanism, then state important behavior or constraints to preserve>
  ```

  Intent rules:
  - `size` is exactly `small`, `medium`, or `large`. Small allows 1 Brief paragraph, at most 90 Brief words, 3 Acceptance items, and 250 Notes words. Medium allows 2 paragraphs, 200 Brief words, 6 items, and 400 Notes words. Large allows 3 paragraphs, 330 Brief words, 10 items, and 600 Notes words.
  - The Brief is prose without a heading, list, or code block. Use only configured project domain names.
  - Acceptance ids are sequential from A1. Keep each item to 25 words or fewer, state a definite observable result, and avoid hedges. Give every item exactly one Verify line using `test` or `test keep` and a configured domain.
  - An Intent must include a concrete implementation approach in Notes: say which code path to change and how, plus the behavior to preserve. Acceptance criteria alone are not a plan. Keep this concise.
  - Write a complete test module to the exact acceptance path. Use `async: true`, test through public functions, and add one `@tag intent: "<slug>/A<n>"` for every Acceptance item. Use `test` for behavior the task adds or changes and `test keep` only for existing behavior that passes on the unchanged checkout. At least one item must use `test`. If a `test keep` item is red on the base, Kogen will reclassify it as `test` and show an approval warning.
  - Do not write to other paths. Do not finish by only describing the files: use the write tool for both. If validation asks for repair, preserve valid content, repair the named rule or missing file, and do not finish until both exact files have been written.

  These are two real accepted Intents from Kogen's `careful-rebuild` history. Copy their concise structure and specificity; do not copy their scope or domain names into the new Intent.

  Accepted example 1: `.kogen/intents/approval-checks/intent.md`
  ```markdown
  ---
  title: Check acceptance tests at approval
  domains: [project, contracts, kernel]
  size: small
  ---
  Three self-builds failed late because an approved acceptance test broke a static rule (a forbidden domain reference) that only the done gate checked. The Developer may not edit the test, so each Build was lost. Let a project declare `acceptance_checks:` that `kogen approve` runs on the acceptance test before it records an approval.

  ## Acceptance
  - A1: `kogen approve` exits non-zero, names the failing check, and records no approval when an acceptance check fails.
  - A2: When every acceptance check passes, `kogen approve` records the approval and leaves no check files in the checkout.
  - A3: An `{path}` argv element is replaced by `test/acceptance/<slug>_test.exs`, which holds the acceptance test while checks run.

  ## Verify
  - A1: test domain=kernel
  - A2: test domain=kernel
  - A3: test domain=kernel

  ## Notes
  `acceptance_checks` uses the same entry shape as `checks` (name, argv, timeout_ms) and defaults to an empty list. Checks run in the project checkout with the project env. Refuse to run them if `test/acceptance/<slug>_test.exs` already exists with different bytes. Kogen's own project.yaml gets `mix credo --strict {path}` and a compile check in a later change, not in this Intent.
  ```

  Accepted example 2: `.kogen/intents/land-on-moved-base/intent.md`
  ```markdown
  ---
  title: Rebase onto a moved base instead of parking
  domains: [engine, workspace, docs]
  size: small
  ---
  When the base branch gains commits while a Build runs, landing parks the Build and asks for a new approval, so a queue of Intents can land only one. When the base did not move, landing still re-runs the full checks and acceptance on the identical tree. Rebase the Candidate onto the new tip and verify it there before landing, and land directly when the base did not move.

  ## Acceptance
  - A1: When the base gains a non-conflicting commit during a Build, the Build lands with that new tip as its commit's parent.
  - A2: After rebasing onto a moved base, the last checks before landing run on exactly the tree that lands.
  - A3: When the base did not move, the checks and acceptance run exactly once in the Build.

  ## Verify
  - A1: test domain=engine
  - A2: test domain=engine
  - A3: test domain=engine

  ## Notes
  A rebase conflict, or red checks after the rebase, still parks the Build as today. Update the existing e2e moved-base scenario to the new behaviour. The landing compare-and-swap stays as it is. `Kogen.Workspace.Checkout` is near its 400-line limit, so put new rebase code in its own small Workspace module.
  ```
  """

  @spec run(Opts.t(), String.t(), String.t(), [map()], String.t() | nil, non_neg_integer()) ::
          {:ok, ShapePass.t()} | {:error, term()}
  def run(%Opts{} = opts, slug, task, history, failure_text, turn_offset) do
    with :ok <- valid_request(slug, task, history, failure_text, turn_offset, opts),
         {:ok, transcript_path} <- Recording.path(opts),
         {:ok, items} <-
           input_items(
             slug,
             task,
             Map.keys(opts.project.domains),
             history,
             failure_text,
             opts.workdir
           ) do
      started_at = System.monotonic_time(:millisecond)

      state = %State{
        opts: opts,
        slug: slug,
        transcript_path: transcript_path,
        items: items,
        calls: [],
        turns: turn_offset,
        turn_offset: turn_offset,
        deadline: started_at + opts.limits.wall_ms
      }

      shape_loop(state)
    end
  end

  defp shape_loop(%State{} = state) do
    local_turns = state.turns - state.turn_offset
    remaining_ms = max(state.deadline - System.monotonic_time(:millisecond), 0)

    cond do
      local_turns >= state.opts.limits.max_turns ->
        error(:shape_turn_limit, "Shaper exhausted its turn limit.")

      remaining_ms == 0 ->
        error(:shape_wall_limit, "Shaper exhausted its wall time limit.")

      true ->
        shape_turn(state, remaining_ms)
    end
  end

  defp shape_turn(%State{} = state, remaining_ms) do
    {model, effort} = state.opts.models.builder

    request = %ExchangeRequest{
      stage: :shape,
      turn: state.turns + 1,
      model: model,
      effort: effort,
      instructions: @instructions,
      items: state.items,
      tool_names: Codec.tool_names(:shaper),
      remaining_ms: remaining_ms
    }

    call_started = System.monotonic_time(:millisecond)

    case Exchange.respond(state.opts, request) do
      {:ok, %ModelResponse{} = response} ->
        accept_response(state, response, model, effort, call_started)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp accept_response(state, response, model, effort, call_started) do
    call = %ShapeCall{
      stage: :shape,
      model: model,
      effort: effort,
      tokens: Usage.zero() |> Codec.usage(response.usage) |> Usage.to_map(),
      wall_ms: elapsed(call_started)
    }

    case record_model_usage(state, call) do
      :ok ->
        state = %{
          state
          | turns: state.turns + 1,
            items: state.items ++ response.raw_items,
            calls: [call | state.calls]
        }

        if response.tool_calls == [],
          do: complete(state, response, []),
          else: run_tools(state, response.tool_calls, response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete(%State{} = state, %ModelResponse{text: text}, written_paths) do
    {:ok,
     %ShapePass{
       items: state.items,
       text: text,
       calls: Enum.reverse(state.calls),
       turns: state.turns - state.turn_offset,
       written_paths: Enum.uniq(written_paths)
     }}
  end

  defp run_tools(%State{} = state, calls, %ModelResponse{} = response) do
    calls
    |> Enum.reduce_while({:ok, state, []}, fn %ToolCall{} = call, {:ok, current, written_paths} ->
      case run_tool(current, call) do
        {:ok, updated, paths} -> {:cont, {:ok, updated, written_paths ++ paths}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> continue_loop(response)
  end

  defp run_tool(%State{} = state, %ToolCall{} = call) do
    with :ok <- record(state, :tool_call, call),
         %ToolResult{} = result <- ShaperTools.run(state.opts, call, output_paths(state.slug)),
         :ok <- record(state, :tool_result, %{call: call, result: result}) do
      output = Codec.function_output(call.id, result.output)
      written_paths = if call.name == "write" and not result.is_error, do: result.paths, else: []
      {:ok, %{state | items: state.items ++ [output]}, written_paths}
    end
  end

  defp continue_loop({:ok, %State{} = state, written_paths}, %ModelResponse{} = response) do
    if Enum.any?(written_paths, &(&1 in output_paths(state.slug))) do
      complete(state, response, written_paths)
    else
      shape_loop(state)
    end
  end

  defp continue_loop({:error, reason}, _response), do: {:error, reason}

  defp input_items(slug, task, domains, [], nil, _workdir) do
    configured_domains = domains |> Enum.sort() |> Enum.join(", ")

    text =
      "Slug: #{slug}\n\nConfigured project domains: #{configured_domains}. Use only these names in the Intent and Verify lines.\n\nTask statement:\n#{task}\n\nWrite the Intent to `.kogen/intents/#{slug}/intent.md` and its acceptance test to `.kogen/acceptance/#{slug}_test.exs`."

    {:ok, [Codec.user_item(text)]}
  end

  defp input_items(slug, _task, _domains, history, failure_text, workdir)
       when is_list(history) and is_binary(failure_text) do
    paths =
      slug
      |> output_paths()
      |> Enum.map_join("\n", fn path ->
        case File.lstat(Path.join(workdir, path)) do
          {:ok, %File.Stat{type: :regular}} ->
            "- `#{path}`: present on disk. Keep it in place; change it only if the failure below requires a correction."

          _missing_or_unreadable ->
            "- `#{path}`: missing or unreadable. Write it during this repair pass at this exact path."
        end
      end)

    repair =
      "Validation failed. Repair the generated files in this conversation. The required paths and their current state are:\n" <>
        paths <>
        "\nBoth exact paths must exist after this pass. Every missing path must be written now. " <>
        "Do not delete required files. The available tools can read, search, and write files; they cannot remove them. " <>
        "Preserve present content unless the failure below requires a focused correction.\n\n" <>
        "Exact failure output:\n\n" <> failure_text

    {:ok, history ++ [Codec.user_item(repair)]}
  end

  defp input_items(_slug, _task, _domains, _history, _failure_text, _workdir),
    do: error(:invalid_shape_history, "Shaper repair history is invalid.")

  defp valid_request(slug, task, history, failure_text, turn_offset, opts) do
    with :ok <- valid_slug(slug),
         :ok <- valid_task(task),
         :ok <- valid_history(history, failure_text),
         :ok <- valid_turn_offset(turn_offset) do
      valid_limits(opts)
    end
  end

  defp valid_slug(slug) do
    if is_binary(slug) and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug),
      do: :ok,
      else: error(:invalid_slug, "Slug must use lowercase letters, digits, and dashes.")
  end

  defp valid_task(task) do
    if is_binary(task) and String.trim(task) != "",
      do: :ok,
      else: error(:empty_task, "Task statement must not be empty.")
  end

  defp valid_history([], nil), do: :ok
  defp valid_history(history, failure) when is_list(history) and is_binary(failure), do: :ok

  defp valid_history(_history, _failure),
    do: error(:invalid_shape_history, "Shaper history or failure text is invalid.")

  defp valid_turn_offset(value) when is_integer(value) and value >= 0, do: :ok

  defp valid_turn_offset(_value),
    do: error(:invalid_turn_offset, "Shaper turn offset must be non-negative.")

  defp valid_limits(opts) do
    cond do
      not is_integer(opts.limits.max_turns) or opts.limits.max_turns < 1 ->
        error(:invalid_turn_limit, "max_turns must be positive.")

      not is_integer(opts.limits.wall_ms) or opts.limits.wall_ms < 1 ->
        error(:invalid_wall_limit, "wall_ms must be positive.")

      true ->
        :ok
    end
  end

  defp record(state, event, payload),
    do: Recording.append(state.opts, event, :shape, state.turns, payload)

  defp record_model_usage(state, %ShapeCall{} = call),
    do: Recording.append(state.opts, :model_usage, :shape, state.turns + 1, call)

  defp output_paths(slug),
    do: [".kogen/intents/#{slug}/intent.md", ".kogen/acceptance/#{slug}_test.exs"]

  defp elapsed(started), do: max(System.monotonic_time(:millisecond) - started, 0)
  defp error(reason, detail), do: {:error, %Error{reason: reason, detail: detail}}
end
