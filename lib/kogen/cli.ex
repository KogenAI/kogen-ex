defmodule Kogen.Cli do
  @moduledoc "Command-line parsing and static help. Pure: no I/O and no other domains."
  use Boundary, deps: [], exports: [Args, Arguments, Help, Version]
end
