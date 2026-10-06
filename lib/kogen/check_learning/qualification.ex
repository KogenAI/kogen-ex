defmodule Kogen.CheckLearning.Qualification do
  @moduledoc false
  alias Kogen.CheckLearning.Adoption
  alias Kogen.CheckLearning.Codec
  alias Kogen.CheckLearning.Sample
  alias Kogen.CheckLearning.Store

  @spec run(Path.t(), Path.t(), Path.t(), map()) :: {:ok, map()} | {:error, term()}
  def run(proposal_path, spec_path, root, env) do
    with {:ok, proposal} <- Codec.read_proposal(proposal_path),
         :ok <- recurring(proposal),
         {:ok, spec} <- Codec.read_spec(spec_path),
         {:ok, rule} <- Store.read_source(root, spec.rule_path),
         {:ok, evidence} <- File.read(proposal_path),
         directory = directory(proposal_path),
         :ok <- File.mkdir_p(directory),
         {:ok, rows} <- Sample.run(spec, root, directory, env, rule),
         {:ok, ^rule} <- Store.read_source(root, spec.rule_path) do
      publish(directory, proposal, spec, rule, evidence, rows)
    else
      {:ok, _changed_rule} -> {:error, :candidate_rule_changed_during_sample}
      {:error, _reason} = error -> error
    end
  end

  defp recurring(%{status: "candidate", observations: [_first, _second | _]}), do: :ok
  defp recurring(_proposal), do: {:error, :proposal_not_recurring}

  defp directory(path),
    do:
      Path.join(
        Path.dirname(path),
        "sample-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
      )

  defp publish(directory, proposal, spec, rule, evidence, rows) do
    metrics = metrics(rows)
    ready? = ready?(rows, metrics)

    result = %{
      schema: 1,
      proposal_id: proposal.id,
      target: proposal.target,
      proposal_sha256: Store.digest(evidence),
      rule_sha256: Store.digest(rule),
      rule_path: spec.rule_path,
      argv: spec.argv,
      expected_feedback: spec.feedback,
      planted_bad_example: spec.planted_bad,
      valid_contrasting_examples: spec.valid_examples,
      precision_sample: rows,
      metrics: metrics,
      adoption_ready: ready?,
      blocking: false,
      approval: "caller required for this new protected rule",
      measured_build_effect: %{
        checker_wall_ms: Enum.sum(Enum.map(rows, & &1.wall_ms)),
        observed_builds: proposal.observations,
        adoption_benefit: "not measured; retain later Build comparisons"
      }
    }

    write_result(directory, proposal, rule, evidence, result)
  end

  defp write_result(directory, proposal, rule, evidence, result) do
    path = Path.join(directory, "qualification.json")

    with :ok <- Store.write(path, result),
         :ok <- Store.write_text(Path.join(directory, "proposal-evidence.json"), evidence),
         :ok <- Store.write_text(Path.join(directory, "candidate-rule"), rule),
         {:ok, intent} <- Adoption.draft(directory, proposal, result, result.adoption_ready) do
      {:ok,
       %{
         report: path,
         adoption_intent: intent,
         adoption_ready: result.adoption_ready,
         precision: result.metrics.precision
       }}
    end
  end

  defp metrics(rows) do
    real = Enum.filter(rows, &(&1.scope == "real"))
    tp = Enum.count(real, &(&1.expected == "bad" and &1.verdict == "bad"))
    fp = Enum.count(real, &(&1.expected == "valid" and &1.verdict == "bad"))

    %{
      real_cases: length(real),
      true_positives: tp,
      false_positives: fp,
      false_negatives: Enum.count(real, &(&1.expected == "bad" and &1.verdict == "valid")),
      errors: Enum.count(rows, &(&1.verdict == "error")),
      precision: if(tp + fp > 0, do: tp / (tp + fp))
    }
  end

  defp ready?(rows, metrics) do
    controls = Enum.reject(rows, &(&1.scope == "real"))

    metrics.errors == 0 and metrics.true_positives > 0 and metrics.false_negatives == 0 and
      metrics.precision >= 0.9 and Enum.all?(controls, &(&1.verdict == &1.expected))
  end
end
