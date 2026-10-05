defmodule Kogen.Project.Loader do
  @moduledoc false

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Project
  alias Kogen.Contracts.Yaml
  alias Kogen.Project.BuildSettings

  @project_keys ~w(name checks format acceptance_checks setup setup_outputs fix diagnose protected_paths gate_paths domains env sandbox base account build)
  @env_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @type error :: %{line: pos_integer() | nil, message: String.t()}

  @spec load(Path.t()) :: {:ok, Project.t()} | {:error, [error()]}
  def load(checkout_root) do
    path = Path.join([checkout_root, ".kogen", "project.yaml"])

    case File.read(path) do
      {:ok, source} -> load_source(source, checkout_root)
      {:error, reason} -> error("cannot read #{path}: #{inspect(reason)}")
    end
  end

  defp load_source(source, checkout_root) do
    case Yaml.parse(source) do
      {:ok, document} when is_map(document) -> validate_document(document, checkout_root)
      {:ok, _value} -> error("project.yaml must contain a map at the document root")
      {:error, issues} -> {:error, issues}
    end
  end

  defp validate_document(document, checkout_root) do
    {attributes, field_errors} = project_fields(document, checkout_root)
    errors = unknown_keys(document, @project_keys, "project") ++ field_errors
    project_result(errors, attributes)
  end

  defp project_fields(document, checkout_root) do
    {name, name_errors} = name(document)
    {collections, collection_errors} = project_collections(document)
    {settings, setting_errors} = project_settings(document)
    {identity, identity_errors} = project_identity(document)

    attributes = [root: checkout_root, name: name] ++ collections ++ settings ++ identity
    {attributes, name_errors ++ collection_errors ++ setting_errors ++ identity_errors}
  end

  defp project_identity(document) do
    {base, base_errors} = optional_string(document, "base", "base")
    {account, account_errors} = account(document)
    {build, build_errors} = build(document)
    {[base: base, account: account, build: build], base_errors ++ account_errors ++ build_errors}
  end

  defp optional_string(document, key, label) do
    case Map.fetch(document, key) do
      {:ok, value} when is_binary(value) and value != "" -> {value, []}
      {:ok, _value} -> {nil, [issue("`#{label}` must be a non-empty string")]}
      :error -> {nil, []}
    end
  end

  # Deprecated (5 Oct 2026): accounts are chosen per machine with `kogen provider use`.
  # Kernel still honours a committed label for one CLI generation and warns.
  defp account(document) do
    {value, errors} = optional_string(document, "account", "account")

    cond do
      errors != [] -> {nil, errors}
      is_nil(value) -> {nil, []}
      Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/, value) -> {value, []}
      true -> {nil, [issue("`account` must be a valid ChatGPT account label")]}
    end
  end

  defp build(document) do
    case_result =
      case Map.fetch(document, "build") do
        {:ok, value} -> BuildSettings.parse(value)
        :error -> {:ok, nil}
      end

    case case_result do
      {:ok, value} -> {value, []}
      {:error, errors} -> {nil, errors}
    end
  end

  defp project_collections(document) do
    {checks, check_errors} = check_specs(document, "checks", true)
    {format, format_errors} = format(document)

    {acceptance_checks, acceptance_check_errors} =
      check_specs(document, "acceptance_checks", false)

    {setup, setup_errors} = check_specs(document, "setup", false)
    {setup_outputs, setup_output_errors} = setup_outputs(document)
    {fix, fix_errors} = check_specs(document, "fix", false)
    {diagnose, diagnose_errors} = diagnostics(document)
    {path_fields, path_errors} = path_lists(document)
    {domains, domain_errors} = domains(document)

    fields = [
      checks: checks,
      format: format,
      acceptance_checks: acceptance_checks,
      setup: setup,
      setup_outputs: setup_outputs,
      fix: fix,
      diagnose: diagnose,
      domains: domains
    ]

    errors = [
      check_errors,
      format_errors,
      acceptance_check_errors,
      setup_errors,
      setup_output_errors,
      fix_errors,
      diagnose_errors,
      path_errors,
      domain_errors
    ]

    {fields ++ path_fields, List.flatten(errors)}
  end

  defp format(document) do
    case Map.fetch(document, "format") do
      {:ok, values} when is_list(values) ->
        validate_string_list(values, "format", "project", true)

      {:ok, _value} ->
        {nil, [issue("`format` must be a list of strings")]}

      :error ->
        {nil, []}
    end
  end

  defp project_settings(document) do
    {env, env_errors} = env(document)
    {sandbox, sandbox_errors} = sandbox(document)
    {[env: env, sandbox: sandbox], env_errors ++ sandbox_errors}
  end

  defp setup_outputs(document) do
    case Map.fetch(document, "setup_outputs") do
      {:ok, paths} when is_list(paths) -> validate_setup_outputs(paths)
      {:ok, _value} -> {[], [issue("`setup_outputs` must be a list of relative paths")]}
      :error -> {[], []}
    end
  end

  defp validate_setup_outputs(paths) do
    {values, errors} = validate_string_list(paths, "setup_outputs", "project", false)

    path_errors =
      paths
      |> Enum.reject(&safe_setup_output_path?/1)
      |> Enum.map(&issue("project.setup_outputs contains unsafe path #{inspect(&1)}"))

    duplicate_errors =
      if length(values) == length(Enum.uniq(values)),
        do: [],
        else: [issue("project.setup_outputs must not contain duplicate paths")]

    overlap_errors = setup_output_overlap_errors(values)
    {values, errors ++ path_errors ++ duplicate_errors ++ overlap_errors}
  end

  defp setup_output_overlap_errors(paths) do
    overlaps =
      for parent <- paths,
          child <- paths,
          parent != child,
          String.starts_with?(child, parent <> "/"),
          do: {parent, child}

    Enum.map(overlaps, fn {parent, child} ->
      issue("project.setup_outputs paths overlap: #{inspect(parent)} and #{inspect(child)}")
    end)
  end

  defp safe_setup_output_path?(path) when is_binary(path) do
    parts = String.split(path, "/")

    path != "" and Path.type(path) == :relative and not String.contains?(path, <<0>>) and
      not String.contains?(path, ["\n", "\r"]) and
      Enum.all?(parts, &(&1 not in ["", ".", "..", ".git"]))
  end

  defp safe_setup_output_path?(_path), do: false

  defp project_result([], attributes), do: {:ok, struct(Project, attributes)}
  defp project_result(errors, _attributes), do: {:error, errors}

  defp name(document) do
    case Map.fetch(document, "name") do
      {:ok, value} when is_binary(value) and value != "" -> {value, []}
      {:ok, _value} -> {nil, [issue("`name` must be a non-empty string")]}
      :error -> {nil, [issue("missing required key `name`")]}
    end
  end

  defp check_specs(document, key, required?) do
    case Map.fetch(document, key) do
      {:ok, values} when is_list(values) -> parse_specs(values, key)
      {:ok, _value} -> {[], [issue("`#{key}` must be a list of CheckSpec maps")]}
      :error when required? -> {[], [issue("missing required key `#{key}`")]}
      :error -> {[], []}
    end
  end

  defp parse_specs(values, key) do
    values
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {value, index}, {specs, errors} ->
      case check_spec(value, "#{key}[#{index}]") do
        {:ok, spec} -> {[spec | specs], errors}
        {:error, spec_errors} -> {specs, errors ++ spec_errors}
      end
    end)
    |> then(fn {specs, errors} -> {Enum.reverse(specs), errors} end)
  end

  defp check_spec(value, label) when is_map(value) do
    keys = ~w(name argv timeout_ms)
    unknown = unknown_keys(value, keys, label)
    {name, name_errors} = string_field(value, "name", label)
    {argv, argv_errors} = string_list_field(value, "argv", label, true)
    {timeout, timeout_errors} = timeout_field(value, label)
    errors = unknown ++ name_errors ++ argv_errors ++ timeout_errors

    if errors == [],
      do: {:ok, %CheckSpec{name: name, argv: argv, timeout_ms: timeout}},
      else: {:error, errors}
  end

  defp check_spec(_value, label), do: {:error, [issue("#{label} must be a map")]}

  defp string_field(value, key, label) do
    case Map.fetch(value, key) do
      {:ok, field} when is_binary(field) and field != "" -> {field, []}
      {:ok, _field} -> {nil, [issue("#{label}.#{key} must be a non-empty string")]}
      :error -> {nil, [issue("#{label} is missing required key `#{key}`")]}
    end
  end

  defp string_list_field(value, key, label, non_empty?) do
    case Map.fetch(value, key) do
      {:ok, fields} when is_list(fields) -> validate_string_list(fields, key, label, non_empty?)
      {:ok, _fields} -> {[], [issue("#{label}.#{key} must be a list of strings")]}
      :error -> {[], [issue("#{label} is missing required key `#{key}`")]}
    end
  end

  defp validate_string_list(fields, key, label, non_empty?) do
    valid = Enum.all?(fields, &(is_binary(&1) and &1 != ""))

    cond do
      non_empty? and fields == [] -> {[], [issue("#{label}.#{key} must not be empty")]}
      not valid -> {[], [issue("#{label}.#{key} must contain only non-empty strings")]}
      true -> {fields, []}
    end
  end

  defp timeout_field(value, label) do
    case Map.fetch(value, "timeout_ms") do
      {:ok, field} when is_binary(field) -> positive_integer(field, "#{label}.timeout_ms")
      {:ok, _field} -> {nil, [issue("#{label}.timeout_ms must be a positive integer")]}
      :error -> {nil, [issue("#{label} is missing required key `timeout_ms`")]}
    end
  end

  defp positive_integer(text, label) do
    case Integer.parse(text) do
      {number, ""} when number > 0 -> {number, []}
      _ -> {nil, [issue("#{label} must be a positive integer")]}
    end
  end

  defp diagnostics(document) do
    case Map.fetch(document, "diagnose") do
      {:ok, values} when is_list(values) -> parse_diagnostics(values)
      {:ok, _value} -> {[], [issue("`diagnose` must be a list of diagnostic maps")]}
      :error -> {[], []}
    end
  end

  defp parse_diagnostics(values) do
    values
    |> Enum.with_index(1)
    |> Enum.reduce({[], []}, fn {value, index}, {items, errors} ->
      case diagnostic(value, index) do
        {:ok, item} -> {[item | items], errors}
        {:error, item_errors} -> {items, errors ++ item_errors}
      end
    end)
    |> then(fn {items, errors} -> {Enum.reverse(items), errors} end)
  end

  defp diagnostic(value, index) when is_map(value) do
    label = "diagnose[#{index}]"
    unknown = unknown_keys(value, ~w(glob argv), label)
    {glob, glob_errors} = string_field(value, "glob", label)
    {argv, argv_errors} = string_list_field(value, "argv", label, true)
    errors = unknown ++ glob_errors ++ argv_errors
    if errors == [], do: {:ok, %{glob: glob, argv: argv}}, else: {:error, errors}
  end

  defp diagnostic(_value, index), do: {:error, [issue("diagnose[#{index}] must be a map")]}

  defp path_lists(document) do
    {protected, protected_errors} = path_list(document, "protected_paths")
    {gate, gate_errors} = path_list(document, "gate_paths")
    {[protected_paths: protected, gate_paths: gate], protected_errors ++ gate_errors}
  end

  defp path_list(document, key) do
    case Map.fetch(document, key) do
      {:ok, paths} when is_list(paths) ->
        validate_string_list(paths, key, "project", false)

      {:ok, _paths} ->
        {[], [issue("`#{key}` must be a list of strings")]}

      :error ->
        {[], []}
    end
  end

  defp domains(document) do
    case Map.fetch(document, "domains") do
      {:ok, values} when is_map(values) -> validate_domains(values)
      {:ok, _values} -> {%{}, [issue("`domains` must be a map of domain names to path lists")]}
      :error -> {%{}, []}
    end
  end

  defp env(document) do
    case Map.fetch(document, "env") do
      {:ok, values} when is_map(values) -> validate_env(values)
      {:ok, _values} -> {%{}, [issue("`env` must be a map of variable names to strings")]}
      :error -> {%{}, []}
    end
  end

  defp sandbox(document) do
    case Map.fetch(document, "sandbox") do
      {:ok, "true"} -> {true, []}
      {:ok, "false"} -> {false, []}
      {:ok, _value} -> {true, [issue("`sandbox` must be a boolean")]}
      :error -> {true, []}
    end
  end

  defp validate_env(values) do
    Enum.reduce(values, {%{}, []}, fn {key, value}, {env, errors} ->
      cond do
        not (is_binary(key) and Regex.match?(@env_name, key)) ->
          {env, errors ++ [issue("`env` has invalid variable name #{inspect(key)}")]}

        not is_binary(value) ->
          {env, errors ++ [issue("`env` value for #{inspect(key)} must be a string")]}

        true ->
          {Map.put(env, key, value), errors}
      end
    end)
  end

  defp validate_domains(values) do
    Enum.reduce(values, {%{}, []}, fn {domain, paths}, {domains, errors} ->
      case validate_string_list(paths, "paths", "domains.#{domain}", false) do
        {valid_paths, []} -> {Map.put(domains, domain, valid_paths), errors}
        {_paths, path_errors} -> {domains, errors ++ path_errors}
      end
    end)
  end

  defp unknown_keys(value, allowed, label) do
    value
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> Enum.sort()
    |> Enum.map(&issue("#{label} has unknown key #{inspect(&1)}"))
  end

  defp issue(message), do: %{line: nil, message: message}
  defp error(message), do: {:error, [issue(message)]}
end
