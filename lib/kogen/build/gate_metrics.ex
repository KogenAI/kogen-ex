defmodule Kogen.Build.GateMetrics do
  @moduledoc "Gate evidence used to compare candidates and measure repair progress."

  defstruct checks_green: false,
            acceptance_only: false,
            failing_acceptance: nil,
            failing_tests: nil,
            failure_count: nil

  @type t :: %__MODULE__{
          checks_green: boolean(),
          acceptance_only: boolean(),
          failing_acceptance: non_neg_integer() | nil,
          failing_tests: non_neg_integer() | nil,
          failure_count: non_neg_integer() | nil
        }
end
