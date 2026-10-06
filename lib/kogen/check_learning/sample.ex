defmodule Kogen.CheckLearning.Sample do
  @moduledoc false
  alias Kogen.CheckLearning.Spec
  alias Kogen.CheckLearning.Store
  alias Kogen.Proc

  @spec run(Spec.t(), Path.t(), Path.t(), map(), binary()) :: {:ok, [map()]} | {:error, term()}
  def run(spec, root, directory, env, rule) do
    checkout = Path.join(directory, "checker-workspace")
    copied_rule = Path.join(checkout, spec.rule_path)
    argv = Enum.map(spec.argv, &String.replace(&1, root <> "/", checkout <> "/"))
    copied_spec = %{spec | argv: argv}

    with {:ok, real} <- real_sources(spec, root),
         :ok <- File.mkdir_p(Path.dirname(copied_rule)),
         :ok <- File.write(copied_rule, rule),
         {:ok, rows} <- checks(copied_spec, checkout, directory, controls(spec) ++ real, env),
         {:ok, ^rule} <- File.read(copied_rule) do
      {:ok, rows}
    else
      {:ok, _changed_rule} -> {:error, :candidate_rule_changed_during_sample}
      {:error, _reason} = error -> error
    end
  end

  defp checks(spec, root, directory, cases, env) do
    Enum.reduce_while(Enum.with_index(cases), {:ok, []}, fn {sample, index}, {:ok, rows} ->
      case check(spec, root, directory, sample, index, env) do
        {:ok, row} -> {:cont, {:ok, rows ++ [row]}}
        error -> {:halt, error}
      end
    end)
  end

  defp real_sources(spec, root) do
    Enum.reduce_while(spec.real_examples, {:ok, []}, fn example, {:ok, cases} ->
      case Store.read_source(root, example.path) do
        {:ok, source} ->
          {:cont, {:ok, cases ++ [Map.merge(example, %{source: source, scope: "real"})]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp controls(spec) do
    bad = %{source: spec.planted_bad, expected: "bad", scope: "planted", path: "planted_bad.ex"}

    valid =
      for {source, index} <- Enum.with_index(spec.valid_examples),
          do: %{source: source, expected: "valid", scope: "control", path: "valid_#{index}.ex"}

    [bad | valid]
  end

  defp check(spec, root, directory, sample, index, env) do
    file = Path.join(directory, "sample_#{index}.ex")
    argv = Enum.map(spec.argv, &String.replace(&1, "{path}", file))

    with :ok <- File.write(file, sample.source),
         {:ok, result} <-
           Proc.run(argv,
             env: env,
             cd: root,
             timeout_ms: 30_000,
             log_path: Path.join(directory, "sample_#{index}.log")
           ) do
      feedback? = String.contains?(result.output_tail, spec.feedback)
      verdict = verdict(result, feedback?)

      {:ok,
       %{
         path: sample.path,
         scope: sample.scope,
         expected: sample.expected,
         verdict: verdict,
         source_sha256: Store.digest(sample.source),
         argv: argv,
         feedback: result.output_tail,
         feedback_matched: feedback?,
         environment_sha256: Store.digest(:erlang.term_to_binary(env, [:deterministic])),
         wall_ms: result.duration_ms
       }}
    end
  end

  defp verdict(%{exit_status: 0, timed_out: false}, _feedback?), do: "valid"
  defp verdict(%{exit_status: 1, timed_out: false}, true), do: "bad"
  defp verdict(_result, _feedback?), do: "error"
end
