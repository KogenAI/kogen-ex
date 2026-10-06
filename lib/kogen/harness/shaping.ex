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
          deadline: integer() | nil
        }
end

defmodule Kogen.Harness.Shaping do
  @moduledoc false

  alias Kogen.Contracts.ExchangeRequest, as: ExchangeRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.Stack
  alias Kogen.Contracts.ToolCall
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Recording
  alias Kogen.Harness.ShapeCall
  alias Kogen.Harness.ShapePass
  alias Kogen.Harness.ShaperTools
  alias Kogen.Harness.Shaping.State
  alias Kogen.Harness.Usage
  alias Kogen.Project.GatePaths
  alias Kogen.Tooling.Error
  alias Kogen.Tooling.ToolResult

  @examples_path Path.expand("../../../priv/harness/shaping_examples.md", __DIR__)
  @external_resource @examples_path
  @examples File.read!(@examples_path)

  @instructions """
  You are Kogen Intent shaper. Read the project and task, then shape a short, actionable Intent and its acceptance test. Do not implement the task. Record product assumptions and shared contracts relied on in optional frontmatter `assumptions` and `shared_contracts`: lists of maps with `name`, repository-relative `path`, and `contains` (minimal stable contract text). Use `blocks_on` for prerequisite Intent slugs. These predicates are rechecked against the current base before Build; unrelated edits must not invalidate them.

  Write exactly these two files, replacing `<slug>` with the requested slug:
  - `.kogen/intents/<slug>/intent.md`
  - `.kogen/acceptance/<slug>_test.exs`

  Use this exact Intent structure. Replace every placeholder with real content; do not add a `## Brief` heading.
  Do not write a `## Request` section. Kogen appends the original task text verbatim after shaping; it is not linted or rewritten.

  ```markdown
  ---
  title: <plain title, at most 72 characters>
  domains: [<one or more configured domain names>]
  size: <small|medium|large>
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
  - The `size` is exactly `small`, `medium`, or `large`. Choose the smallest size that fits the finished Intent; do not default to `medium`. Small and medium are concision guides; large has no limit on outcomes, Brief paragraphs, or Notes words. An Intent is one shaper's complete change of any size, including substantial features and refactors. Never narrow the request or omit an outcome to fit a size.
  - Preserve every requested outcome, shared constraint, and acceptance item in this single Intent. The caller approves the complete change. Implementation may use internal sequential or parallel steps, but every part must be verified together before delivery. Describe such steps in Notes without asking the caller to decompose the change.
  - Every Acceptance item has at most 25 words, regardless of size. Keep each Brief or Acceptance sentence to 30 words or fewer. Add as many sequential Acceptance items as the complete change needs.
  - The Brief is prose without a heading, list, or code block. Use only configured project domain names.
  - Use headings exactly as shown and in this order: `## Acceptance`, `## Verify`, `## Notes`. Write Acceptance entries as one line each with sequential ids (`- A1: ...`, `- A2: ...`); reuse each id exactly once in Verify and in its `@tag intent: "<slug>/A<n>"` test tag.
  - State a definite observable result and avoid hedges. Give every item exactly one Verify line in this form: `- A1: test domain=<configured-domain>` or `- A1: test keep domain=<configured-domain>`. Do not change the order of the words or omit `domain=`.
  - Trim surrounding whitespace from headings, item lines, frontmatter values, and line endings. Do not indent section headings, Acceptance entries, or Verify entries.
  - An Intent must include a concrete implementation approach in Notes: say which code path to change and how, plus the behavior to preserve. Acceptance criteria alone are not a plan. Keep this concise.
  - Set `changes_gate: true` in frontmatter only when the task or planned changes require modifying an effective gate path listed in the task context. Otherwise omit it; merely running or inspecting checks is not a gate-path change.
  - Write a complete test module to the exact acceptance path. Use `async: true`, test through public functions, and add one `@tag intent: "<slug>/A<n>"` for every Acceptance item. Use `test` for behavior the task adds or changes and `test keep` only for existing behavior that passes on the unchanged checkout. At least one item must use `test`. If a `test keep` item is red on the base, Kogen will reclassify it as `test` and show an approval warning.
  - Do not write to other paths. Do not finish by only describing the files: use the write tool for both. If validation asks for repair, preserve valid content, repair the named rule or missing file, and do not finish until both exact files have been written.

  #{@examples}
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
             opts
           ) do
      deadline = wall_deadline(opts.limits.wall_ms)

      state = %State{
        opts: opts,
        slug: slug,
        transcript_path: transcript_path,
        items: items,
        calls: [],
        turns: turn_offset,
        turn_offset: turn_offset,
        deadline: deadline
      }

      shape_loop(state)
    end
  end

  defp shape_loop(%State{} = state) do
    local_turns = state.turns - state.turn_offset
    remaining_ms = remaining_ms(state.deadline)

    cond do
      local_turns >= state.opts.limits.max_turns ->
        error(:shape_turn_limit, "Shaper exhausted its turn limit.")

      is_integer(remaining_ms) and remaining_ms == 0 ->
        error(:shape_wall_limit, "Shaper exhausted its wall time limit.")

      true ->
        shape_turn(state, remaining_ms)
    end
  end

  defp shape_turn(%State{} = state, remaining_ms) do
    {model, effort} = Map.get(state.opts.models, :shaper, {"gpt-6.1-sol", "high"})

    request = %ExchangeRequest{
      stage: :shape,
      turn: state.turns + 1,
      model: model,
      effort: effort,
      instructions: instructions(state.opts.workdir),
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
         %ToolResult{} = result <-
           ShaperTools.run(state.opts, call, output_paths(state.slug, state.opts.workdir)),
         :ok <- record(state, :tool_result, %{call: call, result: result}) do
      output = Codec.function_output(call.id, result.output)
      written_paths = if call.name == "write" and not result.is_error, do: result.paths, else: []
      {:ok, %{state | items: state.items ++ [output]}, written_paths}
    end
  end

  defp continue_loop({:ok, %State{} = state, written_paths}, %ModelResponse{} = response) do
    if Enum.any?(written_paths, &(&1 in output_paths(state.slug, state.opts.workdir))) do
      complete(state, response, written_paths)
    else
      shape_loop(state)
    end
  end

  defp continue_loop({:error, reason}, _response), do: {:error, reason}

  defp input_items(slug, task, domains, [], nil, opts) do
    configured_domains = domains |> Enum.sort() |> Enum.join(", ")
    gate_paths = opts.project |> GatePaths.effective() |> Enum.map_join(", ", &"`#{&1}`")

    text =
      "Slug: #{slug}\n\nConfigured project domains: #{configured_domains}. Use only these names in the Intent and Verify lines.\n\nEffective gate paths: #{gate_paths}. Set `changes_gate: true` only when the task or planned changes require modifying one of these paths. Omit it for unrelated changes; running or inspecting checks alone does not count.\n\nTask statement:\n#{task}\n\nWrite the Intent to `.kogen/intents/#{slug}/intent.md` and its acceptance test to `#{Stack.acceptance_source(opts.workdir, slug)}`."

    {:ok, [Codec.user_item(text)]}
  end

  defp input_items(slug, _task, _domains, history, failure_text, opts)
       when is_list(history) and is_binary(failure_text) do
    workdir = opts.workdir

    paths =
      slug
      |> output_paths(workdir)
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

  defp input_items(_slug, _task, _domains, _history, _failure_text, _opts),
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

      opts.limits.wall_ms != :infinity and
          (not is_integer(opts.limits.wall_ms) or opts.limits.wall_ms < 1) ->
        error(:invalid_wall_limit, "wall_ms must be positive.")

      true ->
        :ok
    end
  end

  defp record(state, event, payload),
    do: Recording.append(state.opts, event, :shape, state.turns, payload)

  defp record_model_usage(state, %ShapeCall{} = call),
    do: Recording.append(state.opts, :model_usage, :shape, state.turns + 1, call)

  defp output_paths(slug, root),
    do: [".kogen/intents/#{slug}/intent.md", Stack.acceptance_source(root, slug)]

  defp instructions(root) do
    case Stack.detect(root) do
      :elixir -> @instructions
      :rails -> Kogen.Harness.RailsShaping.instructions(@instructions)
    end
  end

  defp elapsed(started), do: max(System.monotonic_time(:millisecond) - started, 0)

  defp wall_deadline(:infinity), do: nil
  defp wall_deadline(wall_ms), do: System.monotonic_time(:millisecond) + wall_ms

  defp remaining_ms(nil), do: :infinity
  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
  defp error(reason, detail), do: {:error, %Error{reason: reason, detail: detail}}
end
