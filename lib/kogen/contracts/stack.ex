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

  @spec seed_dirs(t()) :: [Path.t()]
  def seed_dirs(:elixir), do: ["deps", "_build"]
  def seed_dirs(:rails), do: ["vendor/cache"]
end
