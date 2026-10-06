defmodule Kogen.Conversation.PromptCacheKey do
  @moduledoc false

  @spec for_run_stage(Path.t(), atom(), map()) :: String.t()
  def for_run_stage(run_dir, stage, tags \\ %{}) when is_binary(run_dir) and is_atom(stage) do
    attempt = to_string(Map.get(tags, :attempt) || "builder")
    rung = to_string(Map.get(tags, :rung) || attempt)
    epoch = to_string(Map.get(tags, :cache_epoch) || "initial")

    identity = [
      "kogen:responses:v2",
      Path.expand(run_dir),
      Atom.to_string(stage),
      attempt,
      rung,
      epoch
    ]

    :sha256
    |> :crypto.hash(Enum.join(identity, "\0"))
    |> Base.encode16(case: :lower)
  end
end
