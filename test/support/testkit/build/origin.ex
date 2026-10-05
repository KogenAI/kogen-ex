defmodule Kogen.E2e.Build.Origin do
  @moduledoc "Turns the fixture's bare origin into a developer-style repository, or locks its base."

  alias Kogen.Testkit.Git

  @doc "A non-bare origin with `main` checked out, optionally with an uncommitted edit."
  @spec checked_out!(Path.t(), Path.t(), :clean | :dirty | nil) :: Path.t()
  def checked_out!(bare, _parent, nil), do: bare

  def checked_out!(bare, parent, checkout) do
    origin = Path.join(parent, "origin")
    _clone = Git.git!(parent, ["clone", "--quiet", "--no-checkout", bare, origin])
    _refs = Git.git!(origin, ["fetch", "--quiet", bare, "refs/kogen/*:refs/kogen/*"])
    _checkout = Git.git!(origin, ["checkout", "--quiet", "main"])

    if checkout == :dirty do
      path = Path.join(origin, "lib/tiny_app.ex")
      File.write!(path, File.read!(path) <> "# local edit\n")
    end

    origin
  end

  @doc "A provider hook that holds the base ref lock once the given stage is requested."
  @spec lock_base_hook(Path.t(), atom()) :: (atom() -> :ok | :skip)
  def lock_base_hook(origin, stage) do
    lock = Path.join([origin, "refs", "heads", "main.lock"])

    fn
      ^stage -> File.write!(lock, "held by the test")
      _other -> :skip
    end
  end
end
