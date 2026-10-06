defmodule Kogen.Checks.Ledger.ElixirRunner do
  @moduledoc false

  @source Path.expand("../../../../priv/ledger/kogen_ledger_formatter.ex", __DIR__)
  @external_resource @source
  @formatter File.read!(@source)

  @spec prepare(Path.t()) :: :ok | {:error, term()}
  def prepare(run_dir), do: File.write(Path.join(run_dir, "ledger_formatter.ex"), @formatter)

  @spec argv(Path.t(), Path.t(), Path.t()) :: [String.t()]
  def argv(workdir, test_path, run_dir) do
    formatter_path = Path.join(run_dir, "ledger_formatter.ex")

    preload =
      "Code.require_file(#{inspect(formatter_path)}); Code.ensure_loaded!(KogenLedgerFormatter)"

    [
      "elixir",
      "-e",
      preload,
      "-S",
      "mix",
      "test",
      "--formatter",
      "KogenLedgerFormatter",
      "--formatter",
      "ExUnit.CLIFormatter",
      Path.relative_to(test_path, workdir)
    ]
  end
end
