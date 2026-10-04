defmodule Kogen.Harness.PromptCacheKey do
  @moduledoc false

  @spec for_run_stage(Path.t(), atom()) :: String.t()
  def for_run_stage(run_dir, stage) when is_binary(run_dir) and is_atom(stage) do
    :sha256
    |> :crypto.hash(["kogen:responses:v1\0", Path.expand(run_dir), "\0", Atom.to_string(stage)])
    |> Base.encode16(case: :lower)
  end
end
