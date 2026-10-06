defmodule Kogen.Provider do
  @moduledoc "Adapts external language-model providers to the ProviderPort contract."
  use Boundary,
    deps: [Kogen.Accounts, Kogen.Contracts, Kogen.Http, Kogen.Proc, Kogen.ResponseProtocol],
    exports: [
      ChatGPT,
      ChatGPT.Config,
      ChatGPT.Codec,
      ChatGPT.CredentialStore,
      ChatGPT.CredentialStore.Profile,
      ChatGPT.FileStore,
      ChatGPT.KeychainStore,
      ChatGPT.Lock,
      ChatGPT.SIWC,
      Fake,
      Fake.Config
    ]
end
