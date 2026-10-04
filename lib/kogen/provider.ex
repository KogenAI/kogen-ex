defmodule Kogen.Provider do
  @moduledoc "Adapts external language-model providers to the ProviderPort contract."
  use Boundary,
    deps: [Kogen.Contracts, Kogen.Http, Kogen.Proc],
    exports: [
      ChatGPT,
      ChatGPT.Config,
      ChatGPT.Codec,
      ChatGPT.CredentialStore,
      ChatGPT.CredentialStore.Profile,
      ChatGPT.SIWC,
      Fake,
      Fake.Config
    ]
end
