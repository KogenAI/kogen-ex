defmodule Kogen.Checks.FinalPass.Cache do
  @moduledoc false

  alias Kogen.Workspace

  # Cache the output tree, including a red pass that partially rewrote files. A new tree,
  # command declaration, environment or baseline needs a fresh pass. Each pass keeps its
  # own logs so a later revision cannot replace the evidence of an earlier one.
  def once(workdir, run_dir, env, specs, baseline, run) do
    if File.exists?(Path.join(workdir, ".git")) and specs != [] do
      with {:ok, tree} <- Workspace.tree_hash(workdir, env) do
        root = Path.join([run_dir, "final-passes", hash({workdir, specs, env, baseline})])
        directory = Path.join(root, tree)

        case File.read(Path.join(directory, "result.etf")) do
          {:ok, bytes} -> decode(bytes, length(specs))
          {:error, :enoent} -> execute(workdir, root, directory, env, run)
          {:error, reason} -> {:error, {:final_pass_cache, reason}}
        end
      end
    else
      run.(run_dir)
    end
  end

  defp execute(workdir, root, directory, env, run) do
    with :ok <- File.mkdir_p(directory),
         {:ok, results} <- run.(directory),
         {:ok, tree} <- Workspace.tree_hash(workdir, env),
         target = Path.join(root, tree),
         :ok <- File.mkdir_p(target),
         :ok <- File.write(Path.join(target, "result.etf"), :erlang.term_to_binary(results)) do
      {:ok, results}
    end
  end

  defp decode(bytes, count) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      results when is_list(results) and length(results) == count -> {:ok, results}
      _invalid -> {:error, :invalid_final_pass_cache}
    end
  rescue
    ArgumentError -> {:error, :invalid_final_pass_cache}
  end

  defp hash(value),
    do: :sha256 |> :crypto.hash(:erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
end
