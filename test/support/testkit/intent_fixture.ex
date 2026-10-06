defmodule Kogen.Testkit.IntentFixture do
  @moduledoc "Builds Intent sources and parsed Intents for tests."

  @spec parse(binary(), Path.t()) :: {:ok, Kogen.Contracts.Intent.t()} | {:error, term()}
  def parse(source, path), do: Kogen.Intent.parse_binary(source, path)

  def source(attributes \\ %{}) do
    attributes = Map.merge(defaults(), Map.new(attributes))
    acceptance = Enum.map_join(attributes.items, "\n", fn {id, text} -> "- #{id}: #{text}" end)
    verify = Enum.map_join(attributes.verify, "\n", fn {id, body} -> "- #{id}: #{body}" end)

    """
    ---
    title: "#{attributes.title}"
    domains: [#{Enum.join(attributes.domains, ", ")}]
    size: #{attributes.size}
    ---
    #{attributes.brief}

    ## Acceptance
    #{acceptance}

    ## Verify
    #{verify}

    ## Notes
    #{attributes.notes}
    """
  end

  def parsed(attributes \\ %{}) do
    attributes = Map.merge(defaults(), Map.new(attributes))

    case Kogen.Intent.parse_binary(source(attributes), "#{attributes.slug}/intent.md") do
      {:ok, intent} -> intent
      {:error, errors} -> raise "fixture did not parse: #{inspect(errors)}"
    end
  end

  defp defaults do
    %{
      title: "A clear title",
      slug: "valid-intent",
      size: "small",
      domains: ["intent"],
      brief: "The action returns one clear result for each input.",
      items: [{"A1", "The supplied name becomes a lowercase slug."}],
      verify: [{"A1", "test"}],
      notes: ""
    }
  end
end
