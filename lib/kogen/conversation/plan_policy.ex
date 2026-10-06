defmodule Kogen.Conversation.PlanPolicy do
  @moduledoc false

  alias Kogen.Contracts.ModelResponse

  def word_count(text), do: text |> String.split() |> length()

  def response_metrics(:plan, measurements, {:ok, %ModelResponse{} = response}) do
    words = word_count(response.text)

    Map.merge(
      %{plan_output_bytes: byte_size(response.text), plan_output_words: words},
      budget_metrics(measurements, response, words)
    )
  end

  def response_metrics(_stage, _measurements, _result), do: %{}

  defp budget_metrics(%{plan_max_words: max, plan_wrapper_words: wrapper}, response, words) do
    %{
      plan_injection_words: words + wrapper,
      plan_step_count: step_count(response.text),
      plan_budget_status: budget_status(response, words + wrapper, max)
    }
  end

  defp budget_metrics(_measurements, _response, _words), do: %{}

  defp budget_status(%ModelResponse{tool_calls: [_call | _rest]}, _words, _max),
    do: :tools_not_allowed

  defp budget_status(_response, words, max) when words > max, do: :over_budget
  defp budget_status(_response, _words, _max), do: :within_budget

  def within_budget?(text, %{plan_max_words: max, plan_wrapper_words: wrapper}),
    do: word_count(text) + wrapper <= max

  def authority_metrics(intent_text, plan, injection) do
    Map.merge(Map.get(plan || %{}, :measurements, %{}), %{
      intent_bytes: byte_size(intent_text),
      plan_bytes: byte_size(Map.get(plan || %{}, :text, "")),
      plan_injection_bytes: byte_size(injection),
      plan_injection_words: word_count(injection)
    })
  end

  defp step_count(text) do
    case Regex.run(~r/## Implementation steps\s*\n(.*?)(?=\n## |\z)/su, text,
           capture: :all_but_first
         ) do
      [steps] -> length(Regex.scan(~r/^\d+[.)]\s+/m, steps))
      _other -> 0
    end
  end
end
