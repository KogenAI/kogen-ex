root = Path.expand(".")
env = Map.new(["PATH", "TMPDIR", "LANG"], fn key -> {key, System.get_env(key, "")} end)

env =
  Map.merge(env, %{
    "HOME" => Path.join(root, "_build/quality-home"),
    "MIX_ENV" => "dev",
    "MIX_ARCHIVES" => Path.expand("~/.mix/archives"),
    "HEX_HOME" => Path.join(root, "_build/quality-hex"),
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "ERL_FLAGS" => "+S 8:8"
  })

request =
  Kogen.Quality.Request.new(root, Path.join(root, "_build/quality-measure"), env, %{
    base: "careful-rebuild"
  })

{us, commands} = :timer.tc(fn -> Kogen.Quality.commands(request) end)

IO.inspect(
  %{
    seconds: us / 1_000_000,
    tools:
      Enum.map(
        commands,
        &%{
          tool: &1.tool,
          rules: Enum.frequencies_by(&1.findings, fn f -> f.rule end),
          output: &1.output
        }
      )
  }, limit: :infinity)
