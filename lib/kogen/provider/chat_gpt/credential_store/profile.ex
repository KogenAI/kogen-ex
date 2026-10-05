defmodule Kogen.Provider.ChatGPT.CredentialStore.Profile do
  @moduledoc false

  @enforce_keys [:label]
  defstruct [
    :label,
    :client_id,
    :subject,
    :email,
    :expires_at,
    :auth_source,
    signed_in: false,
    plan_usage: false,
    notice_shown: false,
    remote_revoked: nil
  ]

  @type t :: %__MODULE__{
          label: String.t(),
          client_id: String.t() | nil,
          subject: String.t() | nil,
          email: String.t() | nil,
          expires_at: pos_integer() | nil,
          auth_source: String.t() | nil,
          signed_in: boolean(),
          plan_usage: boolean(),
          notice_shown: boolean(),
          remote_revoked: boolean() | nil
        }
end
