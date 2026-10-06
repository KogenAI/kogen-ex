defmodule Kogen.Accounts do
  @moduledoc "Stores provider and account choices shared by the kernel and providers."
  use Boundary, deps: [Kogen.Contracts], exports: [Store]
end
