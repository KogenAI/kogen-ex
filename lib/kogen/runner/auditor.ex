defmodule Kogen.Runner.Auditor do
  @moduledoc false

  # The acceptance-test auditor's prompt and reply. It only corrects a shaped test toward the
  # approved verbatim Request; scope stays as approved.

  alias Kogen.Contracts.JSON

  @diff_limit 60_000

  @instructions """
  You are Kogen's acceptance test auditor. A Candidate passes every check except some acceptance tests, which were generated from the Request and can be wrong. Judge each failing acceptance TEST against the verbatim Request: the Request is the specification, not the test. Answer `valid` when a correct implementation of the Request would pass the test; then the Candidate is wrong. Answer `contradicts` when no correct implementation could pass it: the assertion expects a shape, value or behaviour the Request rules out (for example `assert {:run, 3} in list` when the Request says the list holds `{{:run, 3}, message}` tuples). Answer `over_strict` when the test demands something the Request leaves open: exact wording or output formatting, captured CLI output, ordering, timing or timeouts, environment or framework details, or one implementation choice among several the Request allows. Use the failure output to see what the assertion compared. Return exactly one JSON object: {"items":[{"id":"A1","verdict":"valid|over_strict|contradicts","reason":"one sentence citing the Request"}]} with one entry per failing item id. You have no tools.
  """

  @type verdict :: %{
          id: String.t(),
          verdict: :valid | :over_strict | :contradicts,
          reason: String.t()
        }

  @spec instructions() :: String.t()
  def instructions, do: @instructions

  @doc "The user message: failing ids, Request, test source, failure output and diff."
  @spec input(map()) :: String.t()
  def input(input) do
    String.trim("""
    Failing acceptance items: #{Enum.join(input.failing, ", ")}

    Request (verbatim):
    #{input.request}

    Acceptance test source (#{input.test_path}):
    ```elixir
    #{input.test_source}
    ```

    Failure output from the Candidate's checks:
    #{clip(input.failure)}

    Candidate diff summary (other checks are green):
    #{clip(input.diff_summary)}
    """)
  end

  @doc "One verdict per failing id; items the reply skips or garbles stay valid."
  @spec verdicts(String.t(), [String.t()]) :: [verdict()]
  def verdicts(text, failing) do
    parsed = Map.new(parse_audit(text), &{&1.id, &1})

    Enum.map(failing, fn id ->
      Map.get(parsed, id, %{id: id, verdict: :valid, reason: "The auditor gave no verdict."})
    end)
  end

  @audit_verdicts %{
    "valid" => :valid,
    "over_strict" => :over_strict,
    "contradicts" => :contradicts
  }

  # Verdicts from a JSON reply, tolerating a surrounding code fence; [] if invalid.
  defp parse_audit(text) when is_binary(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> json |> JSON.decode() |> audit_items()
      nil -> []
    end
  end

  defp audit_items({:ok, %{"items" => items}}) when is_list(items),
    do: Enum.flat_map(items, &audit_item/1)

  defp audit_items(_invalid), do: []

  defp audit_item(%{"id" => id, "verdict" => verdict} = item) when is_binary(id) do
    case Map.fetch(@audit_verdicts, verdict) do
      {:ok, value} ->
        reason = Map.get(item, "reason")
        [%{id: id, verdict: value, reason: if(is_binary(reason), do: reason, else: "")}]

      :error ->
        []
    end
  end

  defp audit_item(_item), do: []

  defp clip(text) do
    if String.length(text) > @diff_limit,
      do: String.slice(text, 0, @diff_limit) <> "\n[truncated]",
      else: text
  end
end
