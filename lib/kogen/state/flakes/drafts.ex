defmodule Kogen.State.Flakes.Drafts do
  @moduledoc false
  alias Kogen.State.FileStore
  alias Kogen.State.RunStore

  @spec group([struct()]) :: [{String.t(), [struct()]}]
  def group(observations) do
    observations
    |> Enum.flat_map(fn record -> Enum.map(record.test_ids, &{&1, record}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(&elem(&1, 0))
  end

  @spec update(struct(), [struct()]) :: :ok | {:error, term()}
  def update(run, observations) do
    observations
    |> Enum.filter(&(&1.kind == "flake_excused" and &1.classification == "base_flake"))
    |> group()
    |> Enum.reduce_while(:ok, fn {id, records}, :ok ->
      if length(Enum.uniq_by(records, & &1.run_id)) >= 2 do
        case write(run, id, records) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp write(run, id, records) do
    hash = :sha256 |> :crypto.hash(id) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    directory = Path.join([Path.dirname(Path.dirname(run.dir)), "flake-fixes", "flake-#{hash}"])
    path = Path.join(directory, "intent.md")
    records = Enum.sort_by(records, &{&1.run_id, &1.seed})

    evidence = %{
      test_id: id,
      builds: records |> Enum.map(& &1.run_id) |> Enum.uniq(),
      approval: "caller required",
      observations: Enum.map(records, & &1.evidence)
    }

    with :ok <- File.mkdir_p(directory),
         :ok <- create_intent(path, id, records),
         :ok <-
           FileStore.atomic_write(Path.join(directory, "evidence.json"), JSON.encode!(evidence)),
         do:
           RunStore.record(run, %{
             event: :flake_fix_drafted,
             path: path,
             detail: %{test_id: id, builds: length(evidence.builds), approved: false}
           })
  end

  defp create_intent(path, id, records) do
    domains = records |> Enum.flat_map(& &1.domains) |> Enum.uniq() |> Enum.sort() |> Enum.take(4)
    domains = if domains == [], do: ["test"], else: domains

    text = """
    ---
    title: "Repair repeated base flake"
    domains: [#{Enum.join(domains, ", ")}]
    size: small
    ---
    Make #{id} deterministic while preserving the tested public behavior.

    ## Acceptance
    - A1: The named test passes repeatedly with the recorded failing seeds on the repaired base.
    - A2: A Candidate regression still fails this test and cannot be excused by a passing base probe.

    ## Verify
    - A1: test
    - A2: test

    ## Notes
    Draft only; caller must review scope and approve. See evidence.json for Build identities,
    Candidate/base results, seeds and reproduction argv. Keep the existing gate and queue policy.
    """

    case File.write(path, text, [:exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, _} = error -> error
    end
  end
end
