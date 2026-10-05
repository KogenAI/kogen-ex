defmodule Kogen.Harness.OneShot do
  @moduledoc false

  alias Kogen.Contracts.ModelResponse
  alias Kogen.Harness.Codec
  alias Kogen.Harness.Exchange
  alias Kogen.Harness.Exchange.Request, as: ExchangeRequest
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Usage

  @request_cap_ms 600_000

  # One no-tool model call on the `role` model of `opts.models`, through the resilient Exchange.
  @spec ask(Opts.t(), %{stage: atom(), role: atom(), instructions: String.t(), text: String.t()}) ::
          {:ok, %{text: String.t(), usage: map()}} | {:error, term()}
  def ask(%Opts{} = opts, %{stage: stage, role: role, instructions: instructions, text: text}) do
    {model, effort} = Map.get(opts.models, role, opts.models.strong)

    request = %ExchangeRequest{
      stage: stage,
      turn: 1,
      model: model,
      effort: effort,
      instructions: instructions,
      items: [Codec.user_item(text)],
      tool_names: [],
      remaining_ms: min(opts.limits.wall_ms, @request_cap_ms)
    }

    case Exchange.respond(opts, request) do
      {:ok, %ModelResponse{text: answer, usage: usage}} ->
        {:ok, %{text: answer, usage: Usage.zero() |> Codec.usage(usage) |> Usage.to_map()}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
