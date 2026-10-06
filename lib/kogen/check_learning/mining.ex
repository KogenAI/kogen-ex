defmodule Kogen.CheckLearning.Mining do
  @moduledoc false
  alias Kogen.CheckLearning.Codec
  alias Kogen.CheckLearning.Store
  alias Kogen.Contracts.Failure
  alias Kogen.State
  alias Kogen.Workspace

  @spec observe(struct(), map(), Failure.t()) :: :ok | {:error, term()}
  def observe(run, inputs, %Failure{class: :candidate, detail: detail} = failure)
      when is_binary(detail) and detail != "" do
    root = Path.join(Path.dirname(Path.dirname(run.dir)), "check-proposals")

    :global.trans({{__MODULE__, root}, self()}, fn ->
      Enum.reduce_while(failures(inputs, failure), :ok, fn item, :ok ->
        case mine(root, run, inputs, item) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end)
  end

  def observe(_run, _inputs, _failure), do: :ok

  defp failures(%{stage: :review}, failure) do
    failure.detail
    |> String.split("\n", trim: true)
    |> Enum.take(20)
    |> Enum.map(&%{failure | detail: &1})
  end

  defp failures(_inputs, failure), do: [failure]

  defp mine(root, run, inputs, failure) do
    {family, text} = family(failure.detail)
    pattern = text |> String.replace(~r/:\d+(?::\d+)?/, ":<line>") |> String.replace(~r/\s+/, " ")
    id = "check-" <> binary_part(Store.digest("#{family}/#{failure.reason}/#{pattern}"), 0, 16)
    directory = Path.join(root, id)
    path = Path.join(directory, "proposal.json")

    with {:ok, prior} <- Codec.read_proposal(path),
         {:ok, examples} <- examples(inputs),
         :ok <-
           State.record(run, %{
             event: :check_failure_observed,
             stage: inputs.stage,
             reason: failure.reason,
             detail: failure.detail
           }),
         {:ok, observed} <- observation(run, inputs, failure),
         evidence = Map.put(observed, :examples, examples),
         observations =
           Enum.uniq_by(((prior && prior.observations) || []) ++ [evidence], & &1.key),
         proposal = proposal(id, family, pattern, observations, examples),
         :ok <- Store.write(path, proposal) do
      if length(observations) >= 2 do
        State.record(run, %{
          event: :check_proposal_drafted,
          path: path,
          detail:
            "#{proposal.target}: recurring #{failure.reason}; candidate only, caller approval required"
        })
      else
        :ok
      end
    end
  end

  defp family("style: " <> text), do: {:human_style, text}
  defp family("quality: " <> text), do: {:model_quality, text}
  defp family(text), do: {:model_quality, text}

  defp proposal(id, family, pattern, observations, examples) do
    %{
      schema: 1,
      id: id,
      family: family,
      target: target(family),
      observed_failure: pattern,
      status: if(length(observations) >= 2, do: "candidate", else: "watching"),
      blocking: false,
      approval: "caller required for this new protected rule",
      expected_feedback: pattern,
      planted_bad_example: examples.candidate,
      valid_contrasting_examples: examples.base,
      example_status: "seeds; qualify with planted and labeled controls",
      observations: observations,
      measured_build_effect: effect(observations)
    }
  end

  defp target(:human_style), do: "optimum_credo"
  defp target(:model_quality), do: "kogen_credo"

  defp observation(run, inputs, failure) do
    with {:ok, bytes} <- File.read(Path.join(run.dir, "events.jsonl")),
         {:ok, events} <- read_events(bytes) do
      key = "#{run.id}/#{inputs.attempt}/#{inputs.repairs_left}/#{inputs.stage}"

      {:ok,
       %{
         key: key,
         build_id: run.id,
         attempt: inputs.attempt,
         model: inputs.model,
         stage: inputs.stage,
         failure: failure.reason,
         detail: failure.detail,
         model_wall_ms:
           events
           |> Enum.filter(&(&1.event == "model_stage"))
           |> Enum.map(&(&1.wall_ms || 0))
           |> Enum.sum(),
         repairs: Enum.count(events, &(&1.event == "repair")),
         journal: run.dir
       }}
    end
  end

  defp read_events(bytes) do
    Enum.reduce_while(String.split(bytes, "\n", trim: true), {:ok, []}, fn line, {:ok, events} ->
      case State.decode_event(line) do
        {:ok, event} -> {:cont, {:ok, events ++ [event]}}
        error -> {:halt, error}
      end
    end)
  end

  defp effect(observations) do
    %{
      scope: "observed Build cost at failure; adoption benefit not yet measured",
      samples: Enum.map(observations, &Map.take(&1, [:build_id, :model_wall_ms, :repairs])),
      blocking_enabled: false
    }
  end

  defp examples(inputs) do
    with {:ok, paths} <-
           Workspace.changed_paths(inputs.workdir, inputs.base_sha, inputs.git_env) do
      sources = Enum.take(Enum.filter(paths, &(Path.extname(&1) in [".ex", ".exs"])), 4)

      candidate =
        for path <- sources,
            {:ok, source} <- [Store.read_source(inputs.workdir, path)],
            do: %{path: path, source: bounded(source)}

      base =
        for path <- sources,
            {:ok, source} <- [
              Workspace.read_file_at(inputs.workdir, inputs.base_sha, path, inputs.git_env)
            ],
            do: %{path: path, source: bounded(source)}

      {:ok, %{candidate: candidate, base: base}}
    end
  end

  defp bounded(source) when byte_size(source) <= 16_384, do: source
  defp bounded(source), do: source |> binary_part(0, 16_384) |> String.replace_invalid()
end
