defmodule Kogen.Harness.ToolingContext do
  @moduledoc false

  alias Kogen.Harness.Opts
  alias Kogen.Tooling.Context

  @spec from_opts(Opts.t()) :: Context.t()
  def from_opts(%Opts{} = opts) do
    %Context{
      workdir: opts.workdir,
      run_dir: opts.run_dir,
      project: opts.project,
      proc_mod: opts.proc_mod,
      sandbox: opts.sandbox,
      env: opts.env,
      protected: opts.protected
    }
  end
end
