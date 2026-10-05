defmodule Kogen.Harness.Gate.Arguments do
  @moduledoc false
  def seeded_argv(argv) do
    case seed_in_args(Enum.drop(argv, 2)) do
      {:ok, seed} ->
        {argv, seed}

      :missing ->
        seed = System.unique_integer([:positive, :monotonic])
        {argv ++ ["--seed", Integer.to_string(seed)], seed}

      :invalid ->
        {argv, nil}
    end
  end

  defp seed_in_args(["--seed", value | _rest]), do: parse_seed(value)
  defp seed_in_args(["--seed=" <> value | _rest]), do: parse_seed(value)
  defp seed_in_args([_arg | rest]), do: seed_in_args(rest)
  defp seed_in_args([]), do: :missing

  defp parse_seed(value) do
    case Integer.parse(value) do
      {seed, ""} when seed >= 0 -> {:ok, seed}
      _other -> :invalid
    end
  end

  def retry_argv(argv, test_ids, seed) do
    [executable, "test" | args] = argv

    options =
      args
      |> drop_seed_option()
      |> Enum.reject(&test_selector?/1)

    [executable, "test" | test_ids ++ options ++ ["--seed", Integer.to_string(seed)]]
  end

  defp drop_seed_option(["--seed", _value | rest]), do: drop_seed_option(rest)
  defp drop_seed_option(["--seed=" <> _value | rest]), do: drop_seed_option(rest)
  defp drop_seed_option([arg | rest]), do: [arg | drop_seed_option(rest)]
  defp drop_seed_option([]), do: []

  defp test_selector?(arg),
    do: String.ends_with?(arg, ".exs") or Regex.match?(~r/\.exs:\d+\z/, arg)
end
