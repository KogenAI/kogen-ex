defmodule Kogen.Harness.Stages do
  @moduledoc false

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Context
  alias Kogen.Harness.Error
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Exchange.Request, as: ExchangeRequest
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Pack
  alias Kogen.Harness.Plan
  alias Kogen.Harness.PlanSanitizer
  alias Kogen.Harness.Review

  @review_diff_limit 200_000
  @review_diff_truncated_marker "\n\n[TRUNCATED: Candidate diff continues beyond the 200,000-character review limit.]"

  @review_accept_prompt """
  You are Kogen's advisory code reviewer. Return exactly one JSON object with keys verdict and findings. verdict is accept or revise; findings is an array of strings. Review the supplied Intent, diff, and deterministic check summary. Recommend revise only for a named Acceptance id or a public-behaviour regression. Do not add scope, requirements, dependencies, or files. You have no tools and cannot run checks.
  """

  @spec context_pack(Opts.t(), String.t()) :: {:ok, Pack.t()} | {:error, term()}
  def context_pack(opts, intent_text), do: Context.run(opts, intent_text)

  @spec plan(Opts.t(), Pack.t(), String.t()) :: {:ok, Plan.t()} | {:error, term()}
  def plan(%Opts{} = opts, %Pack{} = pack, intent_text) do
    {model, effort} = Map.get(opts.models, :planner, opts.models.strong)
    request_text = planner_input(pack, intent_text)
    items = [Codec.user_item(request_text)]

    exchange_request = %ExchangeRequest{
      stage: :plan,
      turn: 1,
      model: model,
      effort: effort,
      instructions: planner_instructions(),
      items: items,
      tool_names: [],
      remaining_ms: opts.limits.wall_ms
    }

    case Exchange.respond(opts, exchange_request) do
      {:ok, %ModelResponse{tool_calls: []} = response} ->
        text = PlanSanitizer.clean(response.text, intent_text, opts.project.domains)
        {:ok, %Plan{text: text, usage: response.usage}}

      {:ok, %ModelResponse{}} ->
        error(:plan_tools_not_allowed, "Planner response included an unexpected tool call.")

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec review(Opts.t(), String.t(), String.t(), map()) :: {:ok, Review.t()} | {:error, term()}
  def review(%Opts{} = opts, intent_text, diff, check_summary) do
    {model, effort} = Map.get(opts.models, :reviewer, opts.models.strong)
    review_input = reviewer_input(intent_text, diff, check_summary)
    items = [Codec.user_item(review_input)]

    exchange_request = %ExchangeRequest{
      stage: :review,
      turn: 1,
      model: model,
      effort: effort,
      instructions: @review_accept_prompt,
      items: items,
      tool_names: [],
      remaining_ms: opts.limits.wall_ms
    }

    case Exchange.respond(opts, exchange_request) do
      {:ok, %ModelResponse{tool_calls: [], text: text, usage: usage}} ->
        {:ok, review_result(text, intent_text, usage)}

      {:ok, %ModelResponse{usage: usage}} ->
        {:ok, revise("Reviewer returned a tool call despite having no tools.", usage)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp planner_input(pack, intent_text) do
    String.trim("""
    Approved Intent:
    #{intent_text}

    Read-only context summary:
    #{pack.text}

    Relevant files: #{Enum.join(pack.files, ", ")}
    Code references: #{Enum.join(pack.refs, ", ")}

    Key snippets:
    #{Enum.join(pack.snippets, "\n---\n")}
    """)
  end

  defp planner_instructions do
    String.trim("""
    You are Kogen's one-call implementation planner. Return a concise implementation size estimate and an optional ordered step list. The plan is advice only: the approved Intent controls scope and checks. Use the read-only context and do not invent files, acceptance criteria, or dependencies. Never recommend a dependency unless the Intent explicitly declares it. Do not read global instruction files.
    """)
  end

  defp reviewer_input(intent_text, diff, check_summary) do
    clipped_diff = clip_review_diff(diff)

    String.trim("""
    Approved Intent:
    #{intent_text}

    Candidate diff (up to 200,000 characters; any omitted remainder is marked):
    #{clipped_diff}

    Deterministic checks:
    #{inspect(check_summary, limit: 200, printable_limit: 10_000)}
    """)
  end

  defp clip_review_diff(diff) do
    if String.length(diff) > @review_diff_limit do
      String.slice(diff, 0, @review_diff_limit) <> @review_diff_truncated_marker
    else
      diff
    end
  end

  defp review_result(text, intent_text, usage) do
    case Codec.parse_review(text) do
      {:ok, {verdict, findings}} ->
        scoped_review(verdict, findings, intent_text, usage)

      :error ->
        revise("Review response was not valid strict JSON; one repair may be considered.", usage)
    end
  end

  defp scoped_review(:accept, findings, _intent_text, usage),
    do: %Review{verdict: :accept, findings: findings, usage: usage}

  defp scoped_review(:revise, findings, intent_text, usage) do
    valid_ids = ~r/\bA\d+\b/ |> Regex.scan(intent_text) |> List.flatten()

    accepted_findings =
      Enum.filter(findings, fn finding ->
        Enum.any?(valid_ids, &String.contains?(finding, &1)) or public_regression?(finding)
      end)

    verdict = if accepted_findings == [], do: :accept, else: :revise
    %Review{verdict: verdict, findings: accepted_findings, usage: usage}
  end

  defp public_regression?(finding) do
    Regex.match?(~r/public[- ](?:behavio[u]?r|api|interface)|backward.compatib/i, finding)
  end

  defp revise(finding, usage), do: %Review{verdict: :revise, findings: [finding], usage: usage}

  defp error(reason, detail), do: {:error, %Error{reason: reason, detail: detail}}
end
