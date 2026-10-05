defmodule Kogen.State.Approval do
  @moduledoc "The immutable, hash-bound package approved for one Build."

  @enforce_keys [
    :slug,
    :intent_bytes,
    :intent_sha256,
    :target_branch,
    :base_sha,
    :domains,
    :acceptance_files,
    :protected_manifest,
    :by,
    :at
  ]
  defstruct @enforce_keys ++ [check_baseline: []]

  @type t :: %__MODULE__{
          slug: String.t(),
          intent_bytes: binary(),
          intent_sha256: String.t(),
          target_branch: String.t(),
          base_sha: String.t(),
          domains: [String.t()],
          acceptance_files: %{required(String.t()) => binary()},
          protected_manifest: %{optional(String.t()) => String.t()},
          check_baseline: [map()],
          by: String.t(),
          at: DateTime.t()
        }
end
