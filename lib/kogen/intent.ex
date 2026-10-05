defmodule Kogen.Intent do
  @moduledoc "Loads, hashes, and lints human-authored Markdown Intents."
  use Boundary, deps: [Kogen.Contracts], exports: []

  alias Kogen.Contracts.Intent
  alias Kogen.Intent.Advisory
  alias Kogen.Intent.Parser

  @type parse_error :: %{line: pos_integer(), message: String.t()}
  @type issue :: %{rule: atom(), message: String.t(), line: pos_integer() | nil}

  @spec parse(Path.t()) :: {:ok, Intent.t()} | {:error, [parse_error()]}
  def parse(path), do: Parser.parse_path(path)

  @spec parse_binary(binary(), Path.t()) :: {:ok, Intent.t()} | {:error, [parse_error()]}
  def parse_binary(binary, path), do: Parser.parse_binary(binary, path)

  @spec lint(Intent.t()) :: [issue()]
  def lint(%Intent{} = intent), do: Kogen.Intent.Lint.lint(intent)

  @spec structural_issues(Intent.t()) :: [issue()]
  def structural_issues(intent), do: Enum.reject(lint(intent), &Advisory.style?/1)

  @spec style_warnings(Intent.t()) :: [Kogen.Contracts.ShapeWarning.t()]
  def style_warnings(intent) do
    intent
    |> lint()
    |> Enum.filter(&Advisory.style?/1)
    |> Enum.map(&Advisory.warning/1)
  end

  @spec hash(binary()) :: String.t()
  def hash(binary) when is_binary(binary) do
    :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)
  end
end
