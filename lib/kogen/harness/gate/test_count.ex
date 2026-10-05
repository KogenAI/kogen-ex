defmodule Kogen.Harness.Gate.TestCount do
  @moduledoc false

  @spec failed_test_count([map()], [Kogen.Contracts.CheckSpec.t()]) ::
          non_neg_integer() | nil
  def failed_test_count(commands, specs) do
    test_names = specs |> Enum.filter(&mix_test?(&1.argv)) |> MapSet.new(& &1.name)

    test_commands =
      Enum.filter(commands, &(MapSet.member?(test_names, &1.name) and not &1.base_red?))

    if test_commands != [] and Enum.all?(test_commands, &test_count_known?/1) do
      test_commands
      |> Enum.flat_map(fn
        %{exit_level: 1, findings: findings} -> findings
        _passed -> []
      end)
      |> Enum.filter(&(&1.tool == "exunit" and is_binary(&1.symbol)))
      |> Enum.map(& &1.symbol)
      |> Enum.uniq()
      |> length()
    end
  end

  defp test_count_known?(%{tool: "exunit", exit_level: 0}), do: true

  defp test_count_known?(%{tool: "exunit", exit_level: 1, findings: findings}),
    do: Enum.any?(findings, &(&1.tool == "exunit" and is_binary(&1.symbol)))

  defp test_count_known?(_command), do: false

  defp mix_test?([executable, "test" | _args]), do: Path.basename(executable) == "mix"
  defp mix_test?(_argv), do: false
end
