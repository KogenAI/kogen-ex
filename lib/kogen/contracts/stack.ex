defmodule Kogen.Contracts.Stack do
  @moduledoc "Stack-specific paths and workspace seeds shared by the build domains."

  @type t :: :elixir | :rails

  @spec detect(Path.t()) :: t()
  def detect(root) do
    if File.regular?(Path.join(root, "Gemfile")) and
         File.regular?(Path.join(root, "config/application.rb")),
       do: :rails,
       else: :elixir
  end

  @spec extension(t() | Path.t()) :: String.t()
  def extension(:rails), do: ".rb"
  def extension(:elixir), do: ".exs"
  def extension(root), do: root |> detect() |> extension()

  @spec acceptance_source(t() | Path.t(), String.t()) :: Path.t()
  def acceptance_source(stack, slug), do: ".kogen/acceptance/#{slug}_test" <> extension(stack)

  @spec acceptance_test(t() | Path.t(), String.t()) :: Path.t()
  def acceptance_test(stack, slug), do: "test/acceptance/#{slug}_test" <> extension(stack)

  @doc "Derives installed paths from approved source names, independent of Candidate edits."
  @spec installed_files(%{Path.t() => binary()}) :: %{Path.t() => binary()}
  def installed_files(files) do
    Map.new(files, fn {path, bytes} ->
      {String.replace_prefix(path, ".kogen/acceptance/", "test/acceptance/"), bytes}
    end)
  end

  @spec test_command_index([String.t()]) :: non_neg_integer() | nil
  def test_command_index(argv) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_index(fn [executable, command] ->
      Path.basename(executable) in ["mix", "rails"] and command == "test"
    end)
  end

  @spec seed_dirs(t()) :: [Path.t()]
  def seed_dirs(:elixir), do: ["deps", "_build"]
  def seed_dirs(:rails), do: ["vendor/cache"]

  @spec sandbox_caches(t(), Path.t(), Path.t()) :: [Path.t()]
  def sandbox_caches(:elixir, home, _workspace) do
    Enum.map([".cache/mise", ".hex", ".cache/rebar3", ".npm"], &Path.join(home, &1))
  end

  def sandbox_caches(:rails, _home, workspace) do
    Enum.map(
      [".bundle", ".kogen/bundle", "vendor/bundle", "tmp/cache"],
      &Path.join(workspace, &1)
    )
  end
end
