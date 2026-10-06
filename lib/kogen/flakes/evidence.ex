defmodule Kogen.Flakes.Evidence do
  @moduledoc false
  alias Kogen.Contracts.ProcResult
  alias Kogen.Contracts.Redact
  alias Kogen.Workspace

  @spec snapshot(map()) :: map()
  def snapshot(%{base: base} = opts) when is_binary(base) do
    case Workspace.diff_excluding(opts.workdir, base, [], opts.env) do
      {:ok, patch} -> %{status: "captured", patch: Redact.text(patch)}
      {:error, reason} -> %{status: "unavailable", reason: inspect(reason)}
    end
  end

  def snapshot(_opts), do: %{status: "unavailable", reason: "base identity unavailable"}

  @spec persist(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def persist(opts, classification, data) do
    path =
      Path.join(
        opts.run_dir,
        "flake-evidence-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    evidence = %{
      path: path,
      test_ids: classification.test_ids,
      seed: classification.seed,
      base_sha: opts.base,
      candidate_path: opts.workdir,
      candidate_snapshot: data.snapshot,
      candidate: result(classification.command, classification.argv),
      candidate_retry: result(data.retry, classification.retry_argv),
      base: base_result(data.base, classification.retry_argv),
      classification: classify(data),
      base_failed_test_ids: data.base_ids,
      candidate_failed_test_ids: classification.test_ids -- data.base_ids,
      excused_test_ids: data.excused,
      retry_cost_ms: data.cost,
      domains: opts.project.domains |> Map.keys() |> Enum.sort() |> Enum.take(4),
      policy:
        "matching base failures required; provisional existing cap of two distinct tests per Build; no historical queue-stop threshold"
    }

    with :ok <- File.mkdir_p(opts.run_dir),
         :ok <- File.write(path, Redact.text(JSON.encode!(evidence))),
         :ok <- record(opts, evidence) do
      {:ok, evidence}
    end
  end

  defp record(%{event_recorder: recorder}, evidence) when is_function(recorder, 1),
    do:
      recorder.(%{
        event: :flake_classified,
        test_ids: evidence.test_ids,
        seed: evidence.seed,
        detail: evidence
      })

  defp record(_opts, _evidence), do: :ok

  defp classify(%{
         retry: %{exit_status: 0, timed_out: false},
         base_ids: [],
         base: {:ok, %ProcResult{exit_status: 0, timed_out: false}}
       }), do: "candidate_flake"

  defp classify(%{retry: %{exit_status: 0, timed_out: false}, base_ids: []}),
    do: "unconfirmed_flake"

  defp classify(%{retry: %{exit_status: 0, timed_out: false}}), do: "base_flake"
  defp classify(_data), do: "persistent_failure"

  defp result(command, argv),
    do: %{
      argv: argv,
      exit_status: command.exit_status,
      timed_out: command.timed_out,
      output: Redact.text(command.output),
      log_path: command.log_path
    }

  defp base_result({:ok, %ProcResult{} = command}, argv),
    do: %{
      argv: argv,
      exit_status: command.exit_status,
      timed_out: command.timed_out,
      output: Redact.text(command.output_tail),
      log_path: command.log_path,
      wall_ms: command.duration_ms
    }

  defp base_result({:error, reason}, argv),
    do: %{argv: argv, status: "unavailable", reason: inspect(reason)}
end
