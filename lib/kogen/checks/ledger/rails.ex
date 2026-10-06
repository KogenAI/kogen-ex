defmodule Kogen.Checks.Ledger.Rails do
  @moduledoc false

  @source Path.expand("../../../../priv/ledger/kogen_ledger_reporter.rb", __DIR__)
  @external_resource @source
  @reporter File.read!(@source)

  @spec prepare(Path.t()) :: :ok | {:error, term()}
  def prepare(run_dir), do: File.write(Path.join(run_dir, "ledger_reporter.rb"), @reporter)

  @spec environment(map(), Path.t(), String.t()) :: map()
  def environment(env, run_dir, slug) do
    rubyopt = Enum.find_value(env, "", fn {key, value} -> if key == "RUBYOPT", do: value end)

    rubylib = Enum.find_value(env, "", fn {key, value} -> if key == "RUBYLIB", do: value end)

    Map.merge(
      env,
      Map.new([
        {"KOGEN_LEDGER_SLUG", slug},
        {"RUBYOPT", rubyopt <> " -rbundler/setup -rledger_reporter"},
        {"RUBYLIB", Enum.join(Enum.reject([run_dir, rubylib], &(&1 == "")), ":")}
      ])
    )
  end
end
