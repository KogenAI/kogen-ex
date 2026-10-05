defmodule Kogen.Checks.Feedback do
  @moduledoc false

  defdelegate failed_test_ids(output, workdir), to: Kogen.Feedback
  defdelegate analyze(result), to: Kogen.Feedback
  defdelegate gate(result, spec, paths), to: Kogen.Feedback
  defdelegate overall_exit_level(results), to: Kogen.Feedback
  defdelegate render_model_feedback(results), to: Kogen.Feedback
  defdelegate render_environment_detail(results), to: Kogen.Feedback
end
