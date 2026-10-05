defmodule Kogen.E2e.ScriptedProvider.Call do
  @moduledoc false

  @enforce_keys [:name, :arguments]
  defstruct @enforce_keys

  @type t :: %__MODULE__{name: String.t(), arguments: map()}
end

defmodule Kogen.E2e.ScriptedProvider.Step do
  @moduledoc false

  @enforce_keys [:stage, :text, :calls]
  defstruct @enforce_keys ++ [model: nil, effort: nil, error: nil, usage: nil]

  @type stage :: :context | :plan | :develop | :review | :audit | :shape
  @type t :: %__MODULE__{
          stage: stage(),
          text: String.t(),
          calls: [Kogen.E2e.ScriptedProvider.Call.t()],
          model: String.t() | nil,
          effort: String.t() | nil,
          error: Kogen.Contracts.ProviderError.class() | nil,
          usage: map() | nil
        }
end

defmodule Kogen.E2e.ScriptedProvider.Config do
  @moduledoc false

  @enforce_keys [:server]
  defstruct @enforce_keys

  @type t :: %__MODULE__{server: pid()}
end

defmodule Kogen.E2e.ScriptedProvider.State do
  @moduledoc false

  @enforce_keys [:steps]
  defstruct [:steps, :on_request, requests: [], hook_done?: false, sequence: 0]
end

defmodule Kogen.E2e.ScriptedProvider do
  @moduledoc "Returns stage-checked responses from an explicit, finite test script."
  @behaviour Kogen.Contracts.ProviderPort

  use GenServer

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError
  alias Kogen.Contracts.ToolCall
  alias Kogen.E2e.ScriptedProvider.Call
  alias Kogen.E2e.ScriptedProvider.Config
  alias Kogen.E2e.ScriptedProvider.State
  alias Kogen.E2e.ScriptedProvider.Step

  @zero_usage %{input: 0, cached_input: 0, cache_write: 0, output: 0, reasoning: 0}
  @known_stages [:context, :plan, :develop, :review, :audit, :shape]
  @call_timeout_ms 5_000

  @spec answer(Step.stage(), String.t()) :: Step.t()
  def answer(stage, text) when stage in @known_stages and is_binary(text),
    do: %Step{stage: stage, text: text, calls: []}

  @doc "Answers the stage's request with a provider error of `class`."
  @spec fail(Step.stage(), ProviderError.class()) :: Step.t()
  def fail(stage, class) when stage in @known_stages and is_atom(class),
    do: %Step{stage: stage, text: "", calls: [], error: class}

  @spec write(Step.stage(), Path.t(), String.t()) :: Step.t()
  def write(stage, path, contents) when stage in @known_stages do
    tool_step(stage, "write", %{"path" => path, "content" => contents})
  end

  @spec write_many(Step.stage(), [{Path.t(), String.t()}]) :: Step.t()
  def write_many(stage, files) when stage in @known_stages and is_list(files) do
    calls =
      Enum.map(files, fn {path, contents} ->
        %Call{name: "write", arguments: %{"path" => path, "content" => contents}}
      end)

    %Step{stage: stage, text: "", calls: calls}
  end

  @spec edit(Step.stage(), Path.t(), String.t(), String.t()) :: Step.t()
  def edit(stage, path, old_text, new_text) when stage in @known_stages do
    tool_step(stage, "edit", %{"path" => path, "old_text" => old_text, "new_text" => new_text})
  end

  @spec call(Step.stage(), String.t(), map()) :: Step.t()
  def call(stage, name, arguments) when stage in @known_stages and is_map(arguments),
    do: tool_step(stage, name, arguments)

  @doc "Reports `usage` (`:input`, `:cached_input`, `:output`, `:reasoning` counts) for the step's response."
  @spec with_usage(Step.t(), map()) :: Step.t()
  def with_usage(%Step{} = step, usage) when is_map(usage),
    do: %{step | usage: Map.merge(@zero_usage, usage)}

  @doc """
  Answers only requests for `model` (and `effort`, when given). Parallel ladder members
  request concurrently, so a tagged step is matched by model rather than by script position.
  """
  @spec for_model(Step.t() | [Step.t()], String.t(), String.t() | nil) :: Step.t() | [Step.t()]
  def for_model(steps, model, effort \\ nil)

  def for_model(steps, model, effort) when is_list(steps),
    do: Enum.map(steps, &for_model(&1, model, effort))

  def for_model(%Step{} = step, model, effort) when is_binary(model),
    do: %{step | model: model, effort: effort}

  @spec start_link([Step.t()], (Step.stage() -> :skip | :ok | {:error, term()}) | nil) ::
          GenServer.on_start()
  def start_link(steps, on_request \\ nil) when is_list(steps) do
    if Enum.all?(steps, &match?(%Step{}, &1)) do
      GenServer.start_link(__MODULE__, {steps, on_request})
    else
      {:error, :invalid_script}
    end
  end

  @impl GenServer
  def init({steps, on_request}) do
    {:ok, %State{steps: steps, on_request: on_request}}
  end

  @impl Kogen.Contracts.ProviderPort
  @spec respond(Config.t(), ModelRequest.t()) ::
          {:ok, ModelResponse.t()} | {:error, ProviderError.t()}
  def respond(%Config{server: server}, %ModelRequest{} = request) do
    GenServer.call(server, {:respond, request}, @call_timeout_ms)
  end

  def respond(_config, _request),
    do: provider_error(:malformed, "Scripted provider configuration or request is invalid.")

  @spec remaining(Config.t()) :: non_neg_integer()
  def remaining(%Config{server: server}), do: GenServer.call(server, :remaining)

  @spec requests(Config.t()) :: [ModelRequest.t()]
  def requests(%Config{server: server}), do: GenServer.call(server, :requests)

  @impl GenServer
  def handle_call(:remaining, _from, %State{steps: steps} = state),
    do: {:reply, length(steps), state}

  def handle_call(:requests, _from, %State{requests: requests} = state),
    do: {:reply, Enum.reverse(requests), state}

  def handle_call({:respond, %ModelRequest{} = request}, _from, %State{} = state) do
    with {:ok, stage} <- request_stage(request),
         {:ok, step} <- next_step(state.steps, stage, request),
         {:ok, hooked?} <- run_hook(state, stage) do
      next_state = %{
        state
        | steps: List.delete(state.steps, step),
          hook_done?: hooked?,
          sequence: state.sequence + 1,
          requests: [request | state.requests]
      }

      {:reply, reply(step, next_state.sequence), next_state}
    else
      {:error, %ProviderError{} = error} -> {:reply, {:error, error}, state}
    end
  end

  defp request_stage(%ModelRequest{instructions: instructions, tools: tools}) do
    tool_names = Enum.map(tools, &Map.get(&1, "name"))

    cond do
      String.contains?(instructions, "Kogen Intent shaper") ->
        {:ok, :shape}

      String.contains?(instructions, "acceptance test auditor") ->
        {:ok, :audit}

      String.contains?(instructions, "read-only Context Pack stage") ->
        {:ok, :context}

      String.contains?(instructions, "one-shot implementation plan for a cheaper coding agent") ->
        {:ok, :plan}

      String.contains?(instructions, "implementation planner") ->
        {:ok, :plan}

      String.contains?(instructions, "advisory code reviewer") ->
        {:ok, :review}

      tool_names == ["shell"] ->
        {:ok, :develop}

      tool_names == ["read", "search", "edit", "write", "shell"] ->
        {:ok, :develop}

      true ->
        provider_error(
          :malformed,
          "Scripted provider cannot identify the Build stage from this request."
        )
    end
  end

  # Steps tagged for another model are skipped; otherwise the script is strictly ordered.
  defp next_step(steps, stage, %ModelRequest{model: model, effort: effort}) do
    steps
    |> Enum.filter(&(is_nil(&1.model) or (&1.model == model and &1.effort in [nil, effort])))
    |> next_step(stage)
  end

  defp next_step([], stage),
    do: provider_error(:malformed, "Scripted provider has no response left for stage :#{stage}.")

  defp next_step([%Step{stage: stage} = step | _rest], stage), do: {:ok, step}

  defp next_step([%Step{stage: expected} | _rest], actual) do
    provider_error(
      :malformed,
      "Scripted provider expected stage :#{expected}, but Build requested :#{actual}."
    )
  end

  defp run_hook(%State{hook_done?: true} = state, _stage), do: {:ok, state.hook_done?}
  defp run_hook(%State{on_request: nil} = state, _stage), do: {:ok, state.hook_done?}

  defp run_hook(%State{on_request: hook} = state, stage) do
    case hook.(stage) do
      :skip ->
        {:ok, state.hook_done?}

      :ok ->
        {:ok, true}

      {:error, reason} ->
        provider_error(:transport, "Scripted provider request hook failed: #{inspect(reason)}")

      other ->
        provider_error(:malformed, "Scripted provider hook returned #{inspect(other)}.")
    end
  end

  defp reply(%Step{error: nil} = step, sequence), do: {:ok, response(step, sequence)}

  defp reply(%Step{error: class}, _sequence),
    do: provider_error(class, "Scripted provider returned #{class}.")

  defp response(%Step{} = step, sequence) do
    calls =
      step.calls
      |> Enum.with_index(1)
      |> Enum.map(fn {call, index} -> tool_call(call, sequence, index) end)

    %ModelResponse{
      id: "scripted-response-#{sequence}",
      text: step.text,
      tool_calls: calls,
      usage: step.usage || @zero_usage,
      raw_items: raw_items(step, calls)
    }
  end

  defp tool_call(%Call{} = call, sequence, index) do
    %ToolCall{
      id: "scripted-call-#{sequence}-#{index}",
      name: call.name,
      arguments: call.arguments
    }
  end

  defp raw_items(%Step{calls: []} = step, _calls) do
    [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => step.text}]
      }
    ]
  end

  defp raw_items(%Step{calls: scripted_calls}, calls) do
    scripted_calls
    |> Enum.zip(calls)
    |> Enum.map(fn {%Call{} = script_call, %ToolCall{} = call} ->
      %{
        "type" => "function_call",
        "call_id" => call.id,
        "name" => script_call.name,
        "arguments" => script_call.arguments
      }
    end)
  end

  defp tool_step(stage, name, arguments) do
    call = %Call{name: name, arguments: arguments}
    %Step{stage: stage, text: "", calls: [call]}
  end

  defp provider_error(class, message),
    do: {:error, %ProviderError{class: class, message: message}}
end
