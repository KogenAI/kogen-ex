_ = Application.ensure_all_started(:credo)
tracers = Code.get_compiler_option(:tracers)

if KogenChecks.CapabilityGuard not in tracers do
  Code.put_compiler_option(:tracers, [KogenChecks.CapabilityGuard | tracers])
end

ExUnit.start(formatters: [ExUnit.CLIFormatter, Kogen.Testkit.BudgetFormatter])
ExUnit.after_suite(fn _result -> Kogen.Testkit.BuildSeed.cleanup!() end)
