defmodule KogenChecks.GateWiringTest do
  use Credo.Test.Case

  alias KogenChecks.Check.DomainReach
  alias KogenChecks.Check.ForbiddenCall
  alias KogenChecks.Check.MissingExternalResource
  alias KogenChecks.Check.StringKeyAccess
  alias KogenChecks.Check.TestModuleShape

  @credo_path Path.expand("../../../.credo.exs", __DIR__)

  setup do
    parent = self()

    Credo.CLI.Output.Shell.suppress_output(fn ->
      send(parent, {:execution, Credo.run(["info", "--config-file", @credo_path])})
    end)

    assert_received {:execution, execution}
    {enabled, _only, _ignored} = Credo.Execution.checks(execution)
    {:ok, enabled: Map.new(enabled)}
  end

  test "the configured gate reports attempted integrity bypasses", %{enabled: enabled} do
    cases = [
      {KogenChecks.Check.CtxBag, "def run(ctx), do: ctx.root"},
      {DomainReach, "def run, do: Kogen.Checks.Runner.run([])"},
      {KogenChecks.Check.FailOpenWith,
       "def run do\nwith {:ok, value} <- f() do\nvalue\nelse\n_ -> :ok\nend\nend"},
      {KogenChecks.Check.BroadRescue, "def run do\ntry do\nf()\nrescue\n_ -> :ok\nend\nend"},
      {StringKeyAccess, ~s{def run(data), do: Map.get(data, "key")}}
    ]

    for {check, body} <- cases do
      reports = configured(enabled, check, [source(body)])

      assert Enum.any?(reports, &(&1.exit_status > 0)),
             "#{inspect(check)} allowed a forbidden fixture"
    end
  end

  test "configured process and ambient authority checks reject each forbidden capability", %{
    enabled: enabled
  } do
    for call <- [
          ~s{System.put_env("x", "y")},
          "Process.sleep(1)",
          ~s{System.cmd("true", [])},
          ~s{System.get_env("x")}
        ] do
      reports = configured(enabled, ForbiddenCall, [source("def run, do: " <> call)])
      assert Enum.any?(reports, &(&1.exit_status > 0))
    end

    proc = source(~s{def run, do: System.cmd("true", [])}, "lib/kogen/proc/fixture.ex")
    kernel = source(~s{def run, do: System.get_env("x")}, "lib/kogen/kernel/fixture.ex")
    assert configured(enabled, ForbiddenCall, [proc, kernel]) == []
  end

  test "size ceilings reject excess and accept files within the published limits", %{
    enabled: enabled
  } do
    check = KogenChecks.Check.SizeLimits

    for body <- [
          String.duplicate("# padding\n", 400),
          "def run do\n" <> String.duplicate(":ok\n", 40) <> "end"
        ] do
      assert Enum.any?(configured(enabled, check, [source(body)]), &(&1.exit_status > 0))
    end

    assert configured(enabled, check, [source("def run, do: :ok")]) == []
    domain = KogenChecks.Check.DomainSize

    assert Enum.any?(
             configured(enabled, domain, [source(String.duplicate("# padding\n", 3000))]),
             &(&1.exit_status > 0)
           )

    assert configured(enabled, domain, [source(String.duplicate("# padding\n", 2990))]) == []
  end

  test "resource reads block and public map repetition stays advisory", %{enabled: enabled} do
    resource = source(~s{@data File.read!("input.txt")})
    reports = configured(enabled, MissingExternalResource, [resource])
    assert Enum.any?(reports, &(&1.exit_status > 0))
    declared = source(~s{@external_resource "input.txt"\n@data File.read!("input.txt")})
    assert configured(enabled, MissingExternalResource, [declared]) == []

    maps =
      for n <- 1..3,
          do: source("def f#{n}, do: %{a: 1, b: 2, c: 3, d: 4}", "lib/kogen/build/f#{n}.ex")

    assert [_ | _] = reports = configured(enabled, KogenChecks.Check.RepeatedMapShape, maps)
    assert Enum.all?(reports, &(&1.exit_status == 0))
  end

  test "serial tests are rejected while the async testkit interface and declared dependencies pass",
       %{enabled: enabled} do
    serial =
      to_source_file(
        "defmodule SerialTest do\nuse ExUnit.Case\nend",
        "test/build/serial_test.exs"
      )

    assert Enum.any?(configured(enabled, TestModuleShape, [serial]), &(&1.exit_status > 0))

    async =
      to_source_file(
        "defmodule AsyncTest do\nuse Kogen.Testkit.Case\nend",
        "test/build/async_test.exs"
      )

    assert configured(enabled, TestModuleShape, [async]) == []

    tooling =
      source(
        "def run, do: Kogen.Tooling.Tools.run([])",
        "lib/kogen/harness/fixture.ex",
        "Kogen.Harness.Fixture"
      )

    assert configured(enabled, DomainReach, [tooling]) == []

    codec =
      source(
        ~s{def run(data), do: Map.get(data, "key")},
        "lib/kogen/contracts/yaml.ex",
        "Kogen.Contracts.Yaml"
      )

    assert configured(enabled, StringKeyAccess, [codec]) == []
  end

  test "Checks can use Diagnostics while Diagnostics cannot reach back into Checks", %{
    enabled: enabled
  } do
    caller =
      source(
        "def run(output), do: Kogen.Diagnostics.failed_test_ids(output, \".\")",
        "lib/kogen/checks/fixture.ex",
        "Kogen.Checks.Fixture"
      )

    assert configured(enabled, DomainReach, [caller]) == []

    reverse =
      source(
        "def run, do: Kogen.Checks.Runner.run([])",
        "lib/kogen/diagnostics/fixture.ex",
        "Kogen.Diagnostics.Fixture"
      )

    assert Enum.any?(configured(enabled, DomainReach, [reverse]), &(&1.exit_status > 0))
  end

  test "Harness can use Conversation while Conversation remains independent", %{enabled: enabled} do
    caller =
      source(
        "def run, do: Kogen.Conversation.initial_items(\"intent\", nil, nil, 2)",
        "lib/kogen/harness/fixture.ex",
        "Kogen.Harness.Fixture"
      )

    assert configured(enabled, DomainReach, [caller]) == []

    codec =
      source(
        ~s{def run(data), do: Map.get(data, "key")},
        "lib/kogen/conversation.ex",
        "Kogen.Conversation"
      )

    assert configured(enabled, StringKeyAccess, [codec]) == []

    reverse =
      source(
        "def run, do: Kogen.Harness.develop(nil, nil, nil, nil)",
        "lib/kogen/conversation/fixture.ex",
        "Kogen.Conversation.Fixture"
      )

    assert Enum.any?(configured(enabled, DomainReach, [reverse]), &(&1.exit_status > 0))
  end

  defp configured(enabled, check, files) do
    case Map.fetch(enabled, check) do
      {:ok, params} -> run_check(files, check, params)
      :error -> []
    end
  end

  defp source(body, path \\ "lib/kogen/build/fixture.ex", module \\ "Kogen.Build.Fixture"),
    do: to_source_file("defmodule #{module} do\n#{body}\nend\n", path)
end
