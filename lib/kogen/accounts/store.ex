defmodule Kogen.Accounts.Store do
  @moduledoc false

  alias Kogen.Contracts.Lock
  alias Kogen.Contracts.Yaml

  @providers ~w(chatgpt grok)

  @type choices :: %{default: String.t() | nil, projects: %{Path.t() => String.t()}}

  @spec account_choices(Path.t(), String.t()) :: {:ok, choices()} | {:error, term()}
  def account_choices(root, provider) when provider in @providers do
    case read_document(root) do
      {:ok, document, _path} -> {:ok, Map.get(document.accounts, provider, empty_choices())}
      {:error, {:invalid_accounts_file, path}} -> {:error, {:invalid_accounts_file, path}}
      error -> error
    end
  end

  @spec provider_choices(Path.t()) :: {:ok, choices()} | {:error, term()}
  def provider_choices(root) do
    with {:ok, document, _path} <- read_document(root), do: {:ok, document.selection}
  end

  @spec put_account_choice(Path.t(), String.t(), :default | {:project, Path.t()}, String.t()) ::
          :ok | {:error, term()}
  def put_account_choice(root, provider, target, label)
      when provider in @providers and is_binary(label) do
    with :ok <- valid_label(label) do
      update(root, fn document ->
        choices = Map.get(document.accounts, provider, empty_choices())

        updated =
          case target do
            :default -> %{choices | default: label}
            {:project, path} -> %{choices | projects: Map.put(choices.projects, path, label)}
          end

        put_in(document.accounts[provider], updated)
      end)
    end
  end

  def put_account_choice(_root, _provider, _target, _label),
    do: {:error, :invalid_account_provider}

  @spec put_provider_choice(Path.t(), :default | {:project, Path.t()}, String.t()) ::
          :ok | {:error, term()}
  def put_provider_choice(root, target, provider) when provider in @providers do
    update(root, fn document ->
      selection =
        case target do
          :default ->
            %{document.selection | default: provider}

          {:project, path} ->
            %{document.selection | projects: Map.put(document.selection.projects, path, provider)}
        end

      %{document | selection: selection}
    end)
  end

  def put_provider_choice(_root, _target, _provider), do: {:error, :invalid_account_provider}

  defp update(root, fun) do
    case Lock.with_lock(root, "accounts", fn ->
           with {:ok, document, _path} <- read_document(root) do
             updated = fun.(document)
             write_document(root, updated)
           end
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_document(root) do
    path = Path.join(root, "accounts.yaml")

    case File.read(path) do
      {:ok, source} ->
        with {:ok, parsed} when is_map(parsed) <- Yaml.parse(source),
             {:ok, document} <- decode_document(parsed, path) do
          {:ok, document, path}
        else
          _invalid -> {:error, {:invalid_accounts_file, path}}
        end

      {:error, :enoent} ->
        {:ok, %{accounts: %{}, selection: empty_choices()}, path}

      {:error, reason} ->
        {:error, {:accounts_file_unreadable, path, reason}}
    end
  end

  defp decode_document(parsed, path) do
    if Enum.all?(Map.keys(parsed), &(&1 in (@providers ++ ["selection"]))) do
      with {:ok, accounts} <- decode_accounts(parsed, path),
           {:ok, selection} <- decode_selection(Map.get(parsed, "selection", %{}), path) do
        {:ok, %{accounts: accounts, selection: selection}}
      else
        _invalid -> {:error, {:invalid_accounts_file, path}}
      end
    else
      {:error, {:invalid_accounts_file, path}}
    end
  end

  defp decode_accounts(parsed, path) do
    Enum.reduce_while(@providers, {:ok, %{}}, fn provider, {:ok, accounts} ->
      case decode_choice_section(Map.get(parsed, provider, %{}), provider, path) do
        {:ok, choices} -> {:cont, {:ok, Map.put(accounts, provider, choices)}}
        error -> {:halt, error}
      end
    end)
  end

  defp decode_choice_section(section, key, path) when is_map(section) do
    default = Map.get(section, "default")
    rows = Map.get(section, "projects", [])
    value_key = if key == "selection", do: "provider", else: "account"

    with {:ok, projects} <- decode_projects(rows, value_key),
         true <- valid_section?(section, default, key, projects) do
      {:ok, %{default: default, projects: Map.new(projects)}}
    else
      _invalid -> {:error, {:invalid_accounts_file, path}}
    end
  end

  defp decode_choice_section(_section, _key, path), do: {:error, {:invalid_accounts_file, path}}

  defp decode_projects(rows, value_key) when is_list(rows) do
    projects = Enum.map(rows, &decode_project(&1, value_key))
    if Enum.all?(projects, &match?({_, _}, &1)), do: {:ok, projects}, else: {:error, :invalid}
  end

  defp decode_projects(_rows, _value_key), do: {:error, :invalid}

  defp decode_project(row, value_key) when is_map(row),
    do: {Map.get(row, "path"), Map.get(row, value_key)}

  defp decode_project(_row, _value_key), do: nil

  defp valid_section?(section, default, key, projects) do
    Enum.all?(Map.keys(section), &(&1 in ["default", "projects"])) and
      valid_default?(default, key) and Enum.all?(projects, &valid_project?(&1, key))
  end

  defp valid_default?(nil, _key), do: true
  defp valid_default?(default, "selection"), do: default in @providers
  defp valid_default?(default, _key), do: valid_label?(default)

  defp valid_project?({project, provider}, "selection"),
    do: is_binary(project) and provider in @providers

  defp valid_project?({project, label}, _key), do: is_binary(project) and valid_label?(label)

  defp decode_selection(section, path), do: decode_choice_section(section, "selection", path)

  defp write_document(root, document) do
    contents = serialize(document)
    path = Path.join(root, "accounts.yaml")
    temporary = path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    with :ok <- File.mkdir_p(root),
         :ok <- File.write(temporary, contents, [:binary, :exclusive]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} = error ->
        File.rm(temporary)
        if reason == :eexist, do: {:error, :temporary_file_exists}, else: error
    end
  end

  defp serialize(document) do
    account_text =
      Enum.map_join(@providers, &serialize_section(&1, Map.get(document.accounts, &1)))

    selection_text = serialize_selection(document.selection)

    "# Kogen accounts on this machine, written by kogen provider use.\n" <>
      account_text <> selection_text
  end

  defp serialize_section(_provider, nil), do: ""

  defp serialize_section(provider, choices) do
    choices = live_projects(choices)

    if is_nil(choices.default) and map_size(choices.projects) == 0 do
      ""
    else
      default = if choices.default, do: "  default: #{choices.default}\n", else: ""
      projects = serialize_projects(choices.projects, "account")
      "#{provider}:\n" <> default <> projects
    end
  end

  defp serialize_selection(choices) do
    choices = live_projects(choices)

    if is_nil(choices.default) and map_size(choices.projects) == 0 do
      ""
    else
      default = if choices.default, do: "  default: #{choices.default}\n", else: ""
      projects = serialize_projects(choices.projects, "provider")
      "selection:\n" <> default <> projects
    end
  end

  defp serialize_projects(projects, _value_key) when map_size(projects) == 0, do: ""

  defp serialize_projects(projects, value_key) do
    rows =
      projects
      |> Enum.sort()
      |> Enum.map_join(fn {path, value} ->
        "    - path: #{yaml_string(path)}\n      #{value_key}: #{value}\n"
      end)

    "  projects:\n" <> rows
  end

  defp live_projects(choices) do
    %{choices | projects: Map.filter(choices.projects, fn {path, _value} -> File.dir?(path) end)}
  end

  defp valid_label?(label) when is_binary(label),
    do: Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}\z/, label)

  defp valid_label?(_label), do: false

  defp valid_label(label),
    do: if(valid_label?(label), do: :ok, else: {:error, :invalid_account_label})

  defp empty_choices, do: %{default: nil, projects: %{}}

  defp yaml_string(value),
    do: "\"" <> (value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""
end
