defmodule Kogen.Shaper.Setup do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.Stack
  alias Kogen.Proc
  alias Kogen.Project, as: ProjectDomain
  alias Kogen.Shaper.Request

  @spec run(Request.t(), Project.t()) :: :ok | {:error, term()}
  def run(%Request{} = request, %Project{} = project) do
    env = Map.merge(request.env, project.env)

    case ProjectDomain.run_setup(
           project,
           request.workdir,
           request.setup_cache_root,
           request.base_tree_sha,
           env,
           fn -> run_specs(project.setup, request, env) end
         ) do
      {:ok, setup_result} ->
        case ProjectDomain.record_setup_reuse(request.run_dir, setup_result) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, failure(:environment, :setup_event_failed, inspect(reason))}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_specs(specs, request, env) do
    case File.mkdir_p(Path.join(request.run_dir, "logs")) do
      :ok ->
        Enum.reduce_while(Enum.with_index(specs, 1), :ok, fn {spec, index}, :ok ->
          run_spec(spec, request, env, index)
        end)

      {:error, reason} ->
        {:error, failure(:environment, :setup_log_failed, inspect(reason))}
    end
  end

  defp run_spec(spec, request, env, index) do
    log_path = Path.join([request.run_dir, "logs", "shape-setup-#{index}-#{spec.name}.log"])

    case Proc.run(spec.argv,
           cd: request.workdir,
           env: env,
           timeout_ms: spec.timeout_ms,
           log_path: log_path,
           sandbox: if(Stack.detect(request.workdir) == :rails, do: request.sandbox)
         ) do
      {:ok, %{exit_status: 0, timed_out: false}} ->
        {:cont, :ok}

      {:ok, result} ->
        detail =
          "Setup #{spec.name} failed (status=#{inspect(result.exit_status)}, " <>
            "timed_out=#{result.timed_out}).\n#{result.output_tail}"

        {:halt, {:error, failure(:environment, :setup_failed, detail)}}

      {:error, reason} ->
        detail = "Setup #{spec.name} could not run: #{inspect(reason)}"
        {:halt, {:error, failure(:environment, :setup_failed, detail)}}
    end
  end

  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end
