defmodule Kogen.Checks.Feedback do
  @moduledoc "Public check-feedback interface."
  @type finding :: Kogen.Contracts.Finding.t()
  @type result :: Kogen.Diagnostics.result()
  defdelegate analyze(command), to: Kogen.Diagnostics
  defdelegate failed_test_ids(output, workdir), to: Kogen.Diagnostics
  defdelegate overall_exit_level(results), to: Kogen.Diagnostics
  defdelegate gate(result, spec, paths), to: Kogen.Diagnostics
  defdelegate render_model_feedback(results, changed_ranges), to: Kogen.Diagnostics
  defdelegate render_model_feedback(results), to: Kogen.Diagnostics
  defdelegate render_environment_detail(results), to: Kogen.Diagnostics
  defdelegate write_report(results, run_dir), to: Kogen.Diagnostics
  defdelegate gate_status(results), to: Kogen.Diagnostics
end
