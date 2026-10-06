defmodule Kogen.Grok.CredentialStore.Profile do
  @moduledoc false

  @enforce_keys [:label]
  defstruct [:label, :email, :expires_at, signed_in: false]

  @type t :: %__MODULE__{
          label: String.t(),
          email: String.t() | nil,
          expires_at: pos_integer() | nil,
          signed_in: boolean()
        }
end
