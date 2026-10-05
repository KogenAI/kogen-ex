defmodule Kogen.Intent.Parser.SectionLines do
  @moduledoc false
  defstruct [:current, seen: [], brief: [], acceptance: [], verify: [], notes: [], request: []]
end

defmodule Kogen.Intent.Parser.Metadata do
  @moduledoc false
  defstruct title: "", size: nil, domains: [], changes_gate: false
end

defmodule Kogen.Intent.Parser.VerifyLine do
  @moduledoc false
  defstruct id: "", kind: nil, domain: nil, invalid_word: nil, line: 1
end
