defmodule Kogen.Queue do
  @moduledoc """
  The build queue: Intent states derived from git and run journals, the serial drain, its
  one-per-project lock, and automatic recovery of crashed Builds. Kernel supplies the
  explicit roots, origin, base and Git environment, and the Build itself as a hook.
  """
  use Boundary,
    deps: [Kogen.Intent, Kogen.Contracts, Kogen.Proc, Kogen.State, Kogen.Workspace],
    exports: [
      BuildSummary,
      Drain,
      IntentStatus,
      Lock,
      Recovery,
      Report,
      Selection,
      StateView,
      Status
    ]
end
