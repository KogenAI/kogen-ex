defmodule Kogen.Harness.AuditStage do
  @moduledoc false

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Exchange.Request, as: ExchangeRequest
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Usage

  @diff_limit 60_000
  @request_timeout_ms 600_000

  @instructions """
  You are Kogen's acceptance test auditor. A Candidate passes every check except some acceptance tests, which were generated from the Request and can be wrong. Judge each failing acceptance TEST against the verbatim Request: the Request is the specification, not the test. Answer `valid` when a correct implementation of the Request would pass the test; then the Candidate is wrong. Answer `contradicts` when no correct implementation could pass it: the assertion expects a shape, value or behaviour the Request rules out (for example `assert {:run, 3} in list` when the Request says the list holds `{{:run, 3}, message}` tuples). Answer `over_strict` when the test demands something the Request leaves open: exact wording or output formatting, captured CLI output, ordering, timing or timeouts, environment or framework details, or one implementation choice among several the Request allows. Use the failure output to see what the assertion compared. Return exactly one JSON object: {"items":[{"id":"A1","verdict":"valid|over_strict|contradicts","reason":"one sentence citing the Request"}]} with one entry per failing item id. You have no tools.
  """

  @type verdict :: %{
          id: String.t(),
          verdict: :valid | :over_strict | :contradicts,
          reason: String.t()
        }

  # `input`: failing item ids, the verbatim request, the acceptance test_path and test_source,
  # the gate failure output, and the Candidate's diff_summary.
  @spec run(Opts.t(), map()) :: {:ok, %{verdicts: [verdict()], usage: map()}} | {:error, term()}
  def run(%Opts{} = opts, %{failing: failing} = input) when is_list(failing) do
    {model, effort} = Map.get(opts.models, :auditor, opts.models.strong)

    request = %ExchangeRequest{
      stage: :audit,
      turn: 1,
      model: model,
      effort: effort,
      instructions: @instructions,
      items: [Codec.user_item(input_text(input))],
      tool_names: [],
      remaining_ms: min(opts.limits.wall_ms, @request_timeout_ms)
    }

    case Exchange.respond(opts, request) do
      {:ok, %ModelResponse{text: text, usage: usage}} ->
        usage = Usage.zero() |> Codec.usage(usage) |> Usage.to_map()
        {:ok, %{verdicts: verdicts(text, failing), usage: usage}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Items the reply skips or garbles stay valid: only an explicit verdict demotes a test.
  defp verdicts(text, failing) do
    parsed = Map.new(Codec.parse_audit(text), &{&1.id, &1})

    Enum.map(failing, fn id ->
      Map.get(parsed, id, %{id: id, verdict: :valid, reason: "The auditor gave no verdict."})
    end)
  end

  defp input_text(input) do
    String.trim("""
    Failing acceptance items: #{Enum.join(input.failing, ", ")}

    Request (verbatim):
    #{input.request}

    Acceptance test source (#{input.test_path}):
    ```elixir
    #{input.test_source}
    ```

    Failure output from the Candidate's checks:
    #{clip(Map.get(input, :failure, ""))}

    Candidate diff summary (other checks are green):
    #{clip(input.diff_summary)}
    """)
  end

  defp clip(text) do
    if String.length(text) > @diff_limit,
      do: String.slice(text, 0, @diff_limit) <> "\n[diff truncated]",
      else: text
  end
end
