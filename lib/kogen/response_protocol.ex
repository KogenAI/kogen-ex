defmodule Kogen.ResponseProtocol do
  @moduledoc "Serializes supported Responses protocol variants independently of authentication."
  use Boundary, deps: [Kogen.Contracts], exports: [Codec]
end
