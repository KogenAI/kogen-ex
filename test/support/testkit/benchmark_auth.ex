defmodule Kogen.Testkit.BenchmarkAuth do
  @moduledoc false

  @spec config() :: {:ok, Kogen.Provider.ChatGPT.Config.t()} | {:error, term()}
  def config, do: Kogen.Kernel.benchmark_provider_config()
end
