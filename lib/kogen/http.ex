defmodule Kogen.Http do
  @moduledoc "Owns bounded HTTP requests used by Kogen providers."
  use Boundary, deps: [], exports: [Transport, Transport.Response]
end
