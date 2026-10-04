defmodule KogenChecks.CapabilityGuard do
  @moduledoc """
  Compiler tracer enforcing Kogen's capability boundaries. Process primitives belong
  to Kogen.Proc; ambient root and environment discovery belongs to Kogen.Kernel.
  """

  @type compiler_event :: tuple()

  @spec trace(compiler_event(), Macro.Env.t()) :: :ok
  def trace({kind, meta, target, function, arity}, env)
      when kind in [:remote_function, :remote_macro, :imported_function, :imported_macro] do
    maybe_raise(target, function, arity, meta, env)
    :ok
  end

  def trace(_event, _env), do: :ok

  defp maybe_raise(target, function, arity, meta, env) do
    case violation(target, function, arity, env.module, env.file) do
      nil ->
        :ok

      reason ->
        raise CompileError, file: to_string(env.file), line: meta[:line] || 1, description: reason
    end
  end

  defp violation(target, function, arity, caller, file) do
    cond do
      process_primitive?(target, function) and not process_adapter?(caller, file) ->
        "#{inspect(target)}.#{function}/#{arity} must be called through Kogen.Proc"

      global_mutation?(target, function) ->
        "#{inspect(target)}.#{function}/#{arity} mutates process-global state"

      ambient_discovery?(target, function) and not kernel_module?(caller) ->
        "#{inspect(target)}.#{function}/#{arity} is ambient discovery; only Kogen.Kernel.* may call it"

      true ->
        nil
    end
  end

  defp process_primitive?(System, function), do: function in [:cmd, :shell]
  defp process_primitive?(Port, :open), do: true
  defp process_primitive?(:os, :cmd), do: true
  defp process_primitive?(_target, _function), do: false

  defp process_adapter?(nil, _file), do: false
  defp process_adapter?(Kogen.Proc, _file), do: true
  defp process_adapter?(Kogen.Testkit.Proc, _file), do: true

  defp process_adapter?(caller, file) do
    parts = Module.split(caller)

    Enum.take(parts, 2) == ["Kogen", "Proc"] or testkit_proc_file?(file)
  end

  defp testkit_proc_file?(file) do
    case file |> Path.split() |> Enum.reverse() do
      ["proc.ex", "testkit", "support", "test" | _parents] -> true
      _other -> false
    end
  end

  defp global_mutation?(File, function), do: function in [:cd, :cd!]
  defp global_mutation?(System, function), do: function in [:put_env, :delete_env]
  defp global_mutation?(Application, :put_env), do: true
  defp global_mutation?(Process, :sleep), do: true
  defp global_mutation?(:timer, :sleep), do: true
  defp global_mutation?(_target, _function), do: false

  defp ambient_discovery?(System, function),
    do: function in [:get_env, :fetch_env, :fetch_env!, :user_home, :user_home!]

  defp ambient_discovery?(File, function), do: function in [:cwd, :cwd!]
  defp ambient_discovery?(_target, _function), do: false

  defp kernel_module?(nil), do: false

  defp kernel_module?(caller) do
    parts = Module.split(caller)
    length(parts) > 2 and Enum.take(parts, 2) == ["Kogen", "Kernel"]
  end
end
