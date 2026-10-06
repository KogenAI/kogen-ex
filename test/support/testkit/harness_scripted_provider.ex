defmodule Kogen.Testkit.HarnessScriptedProvider do
  @moduledoc false
  @behaviour Kogen.Contracts.ProviderPort

  alias Kogen.Contracts.ModelRequest
  alias Kogen.Contracts.ModelResponse
  alias Kogen.Contracts.ProviderError

  @spec start([term()]) :: pid()
  def start(responses) do
    {:ok, pid} = Agent.start_link(fn -> %{responses: responses, requests: []} end)
    pid
  end

  @impl true
  @spec respond(pid(), ModelRequest.t()) ::
          {:ok, ModelResponse.t()} | {:error, ProviderError.t()}
  def respond(pid, %ModelRequest{} = request) do
    result =
      Agent.get_and_update(pid, fn state ->
        case state.responses do
          [response | rest] ->
            {provider_result(response),
             %{state | responses: rest, requests: [request | state.requests]}}

          [] ->
            error = %ProviderError{
              class: :malformed,
              message: "Scripted provider ran out of responses."
            }

            {{:error, error}, %{state | requests: [request | state.requests]}}
        end
      end)

    case result do
      :hang ->
        receive do
          :never -> {:error, %ProviderError{class: :transport, message: "Silent provider ended."}}
        end

      result ->
        result
    end
  end

  @spec requests(pid()) :: [ModelRequest.t()]
  def requests(pid), do: Agent.get(pid, &Enum.reverse(&1.requests))

  defp provider_result(:hang), do: :hang
  defp provider_result({:ok, %ModelResponse{}} = result), do: result
  defp provider_result({:error, %ProviderError{}} = result), do: result
  defp provider_result(%ModelResponse{} = response), do: {:ok, response}
end
