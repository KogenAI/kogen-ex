defmodule Kogen.Quality.Request do
  @moduledoc false
  @enforce_keys [:workdir, :run_dir, :env, :deadline]
  defstruct @enforce_keys ++ [base: nil, baseline: nil, sandbox: nil, mix_env: "dev"]

  @type t :: %__MODULE__{
          workdir: Path.t(),
          run_dir: Path.t(),
          env: map(),
          mix_env: String.t(),
          deadline: integer(),
          base: String.t() | nil,
          baseline: Path.t() | nil,
          sandbox: Kogen.Proc.Sandbox.t() | nil
        }

  @spec new(Path.t(), Path.t(), map(), map()) :: t()
  def new(workdir, run_dir, env, options) do
    limit = System.monotonic_time(:millisecond) + 24_000

    %__MODULE__{
      workdir: workdir,
      run_dir: run_dir,
      env: env,
      base: Map.get(options, :base),
      mix_env: Map.get(env, "MIX_ENV", "dev"),
      sandbox: Map.get(options, :sandbox),
      deadline: min(Map.get(options, :deadline, limit), limit)
    }
  end
end
