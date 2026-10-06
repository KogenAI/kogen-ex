defmodule Kogen.Project.StackDefaults do
  @moduledoc false

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Stack

  @spec apply(map(), Path.t()) :: map()
  def apply(document, root) do
    case Stack.detect(root) do
      :elixir -> document
      :rails -> Map.merge(rails(root), document)
    end
  end

  defp rails(root) do
    tools = linters(root)
    format = tools |> List.first() |> formatter()

    defaults =
      Map.new([
        {"checks",
         Enum.map([spec("tests", ["bundle", "exec", "rails", "test"])] ++ tools, &encode/1)},
        {"acceptance_checks", [encode(spec("syntax", ["ruby", "-c", "{path}"]))]},
        {"setup",
         [
           encode(
             spec("bundle", [
               "sh",
               "-c",
               "bundle exec ruby -e 'exit' || GIT_ALLOW_PROTOCOL=file bundle install --local"
             ])
           )
         ]},
        {"protected_paths", ["test/test_helper.rb"]},
        {"gate_paths", ["Gemfile", "Gemfile.lock", "bin/rails", ".standard.yml", ".rubocop.yml"]}
      ])

    if format do
      Map.merge(
        defaults,
        Map.new([{"format", format}, {"fix", [encode(spec("format", format))]}])
      )
    else
      defaults
    end
  end

  @doc "Only enable linters declared by the project, never tools installed on the host."
  @spec linters(Path.t()) :: [CheckSpec.t()]
  def linters(root) do
    declarations = Enum.map_join(["Gemfile", "Gemfile.lock"], "\n", &read(Path.join(root, &1)))

    [
      {"standard", "standardrb", ".standard.yml", ~r/\bgem\s+["']standard["']|^    standard \(/m},
      {"rubocop", "rubocop", ".rubocop.yml",
       ~r/\bgem\s+["']rubocop(?:-[\w-]+)?["']|^    rubocop \(/m}
    ]
    |> Enum.filter(fn {_name, _command, config, pattern} ->
      File.regular?(Path.join(root, config)) or Regex.match?(pattern, declarations)
    end)
    |> Enum.map(fn {name, command, _config, _pattern} ->
      spec(name, ["bundle", "exec", command])
    end)
  end

  defp formatter(nil), do: nil
  defp formatter(%CheckSpec{argv: argv}), do: argv ++ ["-a"]

  defp spec(name, argv), do: %CheckSpec{name: name, argv: argv, timeout_ms: 900_000}

  defp encode(%CheckSpec{} = spec),
    do: Map.new([{"name", spec.name}, {"argv", spec.argv}, {"timeout_ms", "900000"}])

  defp read(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> ""
    end
  end
end
