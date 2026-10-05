defmodule Kogen.Shaper.Progress do
  @moduledoc false
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Redact

  def limit_failure(request, attempt_number, reason, detail) do
    progress(request, attempt_number, "stopped reason=#{reason}")
    {:error, %Failure{class: :candidate, reason: reason, detail: detail}}
  end

  def progress(request, attempt_number, message) do
    line = Redact.text("attempt=#{attempt_number} #{message}")
    log_path = Path.join([request.run_dir, "logs", "shaper.log"])
    _ = File.write(log_path, line <> "\n", [:append])
    IO.puts(:stderr, "shaper #{line}")
  end
end
