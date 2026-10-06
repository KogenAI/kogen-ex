defmodule Kogen.Conversation.BuilderPolicy do
  @moduledoc false

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ToolCall

  @version "incremental-v1"
  @developer_prompt_source Path.expand("../../../priv/prompts/developer.md", __DIR__)
  @external_resource @developer_prompt_source
  @developer_prompt File.read!(@developer_prompt_source)

  def prompt(:full), do: {:ok, @developer_prompt}

  def prompt(:shell) do
    {:ok,
     @developer_prompt <>
       "\n\nShell-only recipe: acceptance tests and the Intent files are read-only, including " <>
       "when using shell commands or formatters. Inspect with `sed -n`, `grep -n`, or `grep -R`; do not " <>
       "assume `rg` or a shell `apply_patch` command is installed. Make focused edits with " <>
       "`python3 - <<'PY'`. Run Elixir commands through `mise exec -- ...` so the pinned Elixir and " <>
       "Erlang versions are used; a direct Elixir wrapper can fail to find `erl`. Inspect only what " <>
       "the next decision needs; combine independent related reads and keep output focused. " <>
       "Emit the command once its arguments are ready. Make one coherent patch, inspect its " <>
       "result, then proceed. Command text contains executable work only, never deliberation " <>
       "or progress prose. All file changes must stay inside the worktree."}
  end

  def disposition(%ModelResponse{tool_calls: []}), do: :progress

  def disposition(%ModelResponse{tool_calls: [%ToolCall{name: "finish", arguments: args}]})
      when args == %{}, do: :finish

  def disposition(%ModelResponse{tool_calls: calls}) do
    if Enum.any?(calls, &(&1.name == "finish")), do: :invalid_finish, else: :tools
  end

  def request_metrics(tool_names, result) do
    if :finish in tool_names do
      Map.merge(
        %{builder_policy: @version, completion_signal: "finish-v1"},
        response_metrics(result)
      )
    else
      %{}
    end
  end

  defp response_metrics({:ok, %ModelResponse{} = response}) do
    %{
      response_kind: disposition(response),
      assistant_text_bytes: byte_size(response.text),
      tool_call_count: length(response.tool_calls),
      tool_argument_bytes:
        Enum.reduce(
          response.tool_calls,
          0,
          &(:erlang.iolist_size(:json.encode(&1.arguments)) + &2)
        )
    }
  end

  defp response_metrics(_error), do: %{}

  def finish_result do
    "Completion requested. Kogen will run the gate."
  end

  def invalid_finish_result do
    "finish requires an empty object and must be the only tool call. Continue implementing, then call finish alone with {}."
  end

  def progress_note do
    "Continue the entire approved Intent with the next useful tool call. Brief progress text does not finish the Build; call finish alone with {} when implementation and targeted verification are complete."
  end
end
