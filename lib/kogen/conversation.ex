defmodule Kogen.Conversation do
  @moduledoc "Approved conversation authority and opt-in continuation checkpoints."
  use Boundary,
    deps: [Kogen.Contracts],
    exports: [Budget, BuilderPolicy, PlanPolicy, PlanShellPrompts]

  alias Kogen.Contracts.JSON
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.Redact

  @sections ~w(obligations findings investigation ruled_out next_steps)
  @instructions """
  Continue the same approved Build by making a checkpoint. Return only a JSON object with
  string fields obligations, findings, investigation, ruled_out, next_steps. Preserve every
  acceptance obligation and constraint, current edits and test outcomes, relevant locations,
  useful investigation, disproven approaches and why they failed, and remaining work.
  Do not claim done, use tools, or change scope. Mark uncertainty honestly. Keep it concise.
  """

  def instructions, do: @instructions

  def due?(items, limit) when is_integer(limit) and limit > 0, do: size(items) >= limit

  def due?(_items, _limit), do: false

  def size(items), do: :erlang.iolist_size(:json.encode(items))

  def checkpoint(%ModelResponse{tool_calls: [], text: text}, authority, items, limit, path) do
    with {:ok, object} when is_map(object) <- JSON.decode(text),
         true <-
           Enum.all?(
             @sections,
             &(is_binary(Map.get(object, &1)) and String.trim(Map.get(object, &1)) != "")
           ) do
      summary = Enum.map_join(@sections, "\n\n", &"#{&1}: #{Map.fetch!(object, &1)}")

      next = [
        user_item(authority),
        user_item("Continuation of the same approved Build.\n\n" <> summary)
      ]

      if size(next) < min(size(items), limit) do
        with :ok <- File.write(path, Redact.text(summary)) do
          {:ok, next, %{before_bytes: size(items), after_bytes: size(next)}}
        end
      else
        {:error, :checkpoint_not_smaller}
      end
    else
      _invalid -> {:error, :invalid_checkpoint}
    end
  end

  def checkpoint(_response, _authority, _items, _limit, _path), do: {:error, :invalid_checkpoint}

  def initial_items(intent_text, plan, nil, repairs_left) do
    [user_item(authority(intent_text, plan, repairs_left))]
  end

  def initial_items(
        intent_text,
        plan,
        %{fresh: true, previous_items: [], failure_text: failure_text},
        repairs_left
      )
      when is_binary(failure_text) do
    user_text =
      authority(intent_text, plan, repairs_left) <>
        "\n\nEscalation summary:\n" <> failure_text

    [user_item(user_text)]
  end

  def initial_items(
        _intent_text,
        _plan,
        %{previous_items: items, failure_text: failure_text},
        _repairs_left
      )
      when is_list(items) and is_binary(failure_text) do
    items ++
      [
        user_item(
          "Kogen's controller reported this failure. Continue the same session and fix it:\n\n" <>
            failure_text
        )
      ]
  end

  def initial_items(intent_text, plan, _invalid_resume, repairs_left) do
    [user_item(authority(intent_text, plan, repairs_left))]
  end

  def authority_metrics(intent_text, plan) do
    injection = if is_nil(plan), do: "", else: plan_content(plan)
    Kogen.Conversation.PlanPolicy.authority_metrics(intent_text, plan, injection)
  end

  def authority(intent_text, plan, repairs_left) do
    plan_content = plan_content(plan)

    String.trim("""
    Approved Intent:
    #{intent_text}

    #{plan_content}

    The controller supplied a remaining repair budget of #{repairs_left} pass(es). The Build Cycle owns that budget.
    Begin work in the supplied worktree.
    """)
  end

  defp plan_content(%{builder_addendum: addendum}) when is_binary(addendum), do: addendum
  defp plan_content(%{text: text}), do: "Implementation plan advice:\n" <> text
  defp plan_content(_plan), do: "Implementation plan advice:\nNo technical plan was supplied."

  defp user_item(text),
    do: %{"role" => "user", "content" => [%{"type" => "input_text", "text" => text}]}
end
