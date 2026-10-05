defmodule Kogen.Shaper.Request do
  @moduledoc false

  @default_limits %{max_turns: 60, wall_ms: :infinity}

  @enforce_keys [
    :workdir,
    :slug,
    :task,
    :model,
    :effort,
    :provider_mod,
    :provider_config,
    :env,
    :git_env,
    :run_dir
  ]
  defstruct @enforce_keys ++
              [sandbox: nil, setup_cache_root: nil, base_tree_sha: nil, limits: @default_limits]

  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = request) do
    with :ok <- validate_project(request),
         :ok <- validate_shape_options(request) do
      validate_runtime_options(request)
    end
  end

  defp validate_project(request) do
    cond do
      not absolute_directory?(request.workdir) -> {:error, :project_unavailable}
      not valid_slug?(request.slug) -> {:error, :invalid_slug}
      true -> :ok
    end
  end

  defp validate_shape_options(request) do
    cond do
      not is_binary(request.task) or String.trim(request.task) == "" ->
        {:error, :empty_task}

      not nonempty_string?(request.model) or not nonempty_string?(request.effort) ->
        {:error, :invalid_model}

      not is_binary(request.run_dir) or Path.type(request.run_dir) != :absolute ->
        {:error, :invalid_run_dir}

      true ->
        :ok
    end
  end

  defp validate_runtime_options(request) do
    cond do
      not is_map(request.env) or not is_map(request.git_env) -> {:error, :invalid_environment}
      not valid_limits?(request.limits) -> {:error, :invalid_limits}
      true -> :ok
    end
  end

  defp absolute_directory?(path),
    do: is_binary(path) and Path.type(path) == :absolute and File.dir?(path)

  defp nonempty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_slug?(slug),
    do: is_binary(slug) and Regex.match?(~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, slug)

  defp valid_limits?(%{max_turns: turns, wall_ms: wall_ms}),
    do:
      is_integer(turns) and turns > 0 and
        (wall_ms == :infinity or (is_integer(wall_ms) and wall_ms > 0))

  defp valid_limits?(_limits), do: false

  @type limits :: %{max_turns: pos_integer(), wall_ms: pos_integer() | :infinity}

  @type t :: %__MODULE__{
          workdir: Path.t(),
          slug: String.t(),
          task: String.t(),
          model: String.t(),
          effort: String.t(),
          provider_mod: module(),
          provider_config: term(),
          env: %{String.t() => String.t()},
          git_env: %{String.t() => String.t()},
          run_dir: Path.t(),
          setup_cache_root: Path.t() | nil,
          base_tree_sha: String.t() | nil,
          sandbox: Kogen.Proc.Sandbox.t() | nil,
          limits: limits()
        }
end

defmodule Kogen.Shaper.Result do
  @moduledoc false

  @enforce_keys [
    :slug,
    :intent_path,
    :acceptance_path,
    :calls,
    :rounds,
    :transcript_path,
    :warnings
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          slug: String.t(),
          intent_path: Path.t(),
          acceptance_path: Path.t(),
          calls: [Kogen.Harness.ShapeCall.t()],
          rounds: pos_integer(),
          transcript_path: Path.t(),
          warnings: [Kogen.Contracts.ShapeWarning.t()]
        }
end
