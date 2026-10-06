defmodule KogenChecks.Check.FailOpenWithTest do
  use Credo.Test.Case

  alias KogenChecks.Check.FailOpenWith

  test "case clauses that map errors to success defaults are low-priority advisories" do
    """
    defmodule X do
      def ancestor?(git_result) do
        case git_result do
          {:ok, 0, _output} -> true
          {:ok, _status, _output} -> false
          {:error, _reason} -> false
        end
      end

      def case_defaults(value) do
        case value do
          {:error, _} -> :ok
          {:error, _reason} -> {:ok, :fallback}
          {:error, reason} -> nil
          {:error, _reason} -> []
          {:error, _reason} -> %{}
          {:error, _reason} -> false
        end
      end
    end
    """
    |> to_source_file("lib/kogen/build/x.ex")
    |> run_check(FailOpenWith)
    |> assert_issues(fn issues ->
      assert length(issues) == 2
      assert Enum.all?(issues, &(&1.category == :warning))
      assert Enum.all?(issues, &(&1.trigger == "case"))
      assert Enum.all?(issues, &(Credo.Priority.to_atom(&1.priority) == :low))
      assert Enum.all?(issues, &(&1.exit_status == 0))
    end)
  end

  test "with/else clauses that map errors to success shapes fail the gate" do
    """
    defmodule X do
      def catch_all(output) do
        with {:ok, prediction} <- parse_prediction(output) do
          prediction
        else
          _invalid_output -> :ok
        end
      end

      def error_to_empty(value) do
        with {:ok, result} <- fetch(value) do
          result
        else
          {:error, _reason} -> []
        end
      end

      def logged_but_swallowed(value) do
        with {:ok, result} <- fetch(value) do
          result
        else
          {:error, reason} ->
            Logger.warning("fetch failed: \#{inspect(reason)}")
            :ok
        end
      end
    end
    """
    |> to_source_file("lib/kogen/build/x.ex")
    |> run_check(FailOpenWith)
    |> assert_issues(fn issues ->
      assert length(issues) == 3
      assert Enum.all?(issues, &(&1.trigger == "with"))
      assert Enum.all?(issues, &(Credo.Priority.to_atom(&1.priority) == :high))
      assert Enum.all?(issues, &(&1.exit_status != 0))
    end)
  end

  test "a with and a case in one file keep their separate exit statuses" do
    """
    defmodule X do
      def f(value) do
        with {:ok, result} <- fetch(value) do
          result
        else
          {:error, _reason} -> nil
        end
      end

      def g(value) do
        case fetch(value) do
          {:ok, result} -> result
          {:error, _reason} -> nil
        end
      end
    end
    """
    |> to_source_file("lib/kogen/build/x.ex")
    |> run_check(FailOpenWith)
    |> assert_issues(fn issues ->
      statuses = issues |> Enum.map(&{&1.trigger, &1.exit_status}) |> Enum.sort()
      assert [{"case", 0}, {"with", status}] = statuses
      assert status != 0
    end)
  end

  test "allows logging, reason propagation, re-raising, and explicit error translation" do
    """
    defmodule X do
      def no_else(value), do: with({:ok, result} <- fetch(value), do: result)

      def logged(value) do
        case value do
          {:error, reason} ->
            Logger.warning("fetch failed: \#{inspect(reason)}")
            :ok
        end
      end

      def translated(value) do
        with {:ok, result} <- fetch(value) do
          result
        else
          {:error, :missing} -> {:error, {:missing, value}}
          {:error, reason} -> {:error, {:read, reason}}
        end
      end

      def preserve(value) do
        with {:ok, result} <- fetch(value) do
          result
        else
          error -> error
        end
      end

      def preserve_reason(value) do
        case value do
          {:error, reason} -> reason
        end
      end

      def re_raise(value) do
        with {:ok, result} <- fetch(value) do
          result
        else
          {:error, reason} -> reraise reason, __STACKTRACE__
        end
      end

      def non_default(value) do
        case value do
          {:error, _reason} -> true
        end
      end

      def unlogged_error_tag(value) do
        case value do
          {:error, :missing} -> false
        end
      end
    end
    """
    |> to_source_file("lib/kogen/build/x.ex")
    |> run_check(FailOpenWith)
    |> refute_issues()
  end

  test "receives report each lost error at its branch without failing the gate" do
    source = """
    defmodule Inbox do
      def await do
        receive do
          {:error, _reason} -> nil
          {:error, _} -> {:ok, :fallback}
          {:error, reason} -> []
        after
          100 -> nil
        end
      end
    end
    """

    source
    |> to_source_file("lib/inbox.ex")
    |> run_check(FailOpenWith)
    |> assert_issues(fn issues ->
      assert Enum.sort(Enum.map(issues, & &1.line_no)) == [4, 5, 6]
      assert Enum.all?(issues, &(&1.trigger == "receive" and &1.exit_status == 0))
      assert Enum.all?(issues, &(Credo.Priority.to_atom(&1.priority) == :low))
      assert Enum.all?(issues, &String.contains?(&1.message, "drops its reason"))
    end)
  end

  test "receives allow handled reasons, message filtering, timeouts and predicate defaults" do
    """
    defmodule Inbox do
      def timeout_only do
        receive do
        after
          100 -> nil
        end
      end

      def await do
        receive do
          {:error, reason} ->
            report(reason)
            nil
          {:error, reason} ->
            Logger.warning(inspect(reason))
            :ok
          {:error, reason} -> {:error, reason}
          {:error, reason} -> raise reason
          {:error, :missing} -> false
          {:error, _reason} -> true
          {:message, _payload} -> nil
          _other -> :ok
        after
          100 -> nil
        end
      end
    end
    """
    |> to_source_file("lib/inbox.ex")
    |> run_check(FailOpenWith)
    |> refute_issues()
  end

  test "does not scan tests" do
    """
    defmodule X do
      def f do
        with :ok <- call() do
          :ok
        else
          _ -> :ok
        end
      end
    end
    """
    |> to_source_file("test/build/x_test.exs")
    |> run_check(FailOpenWith)
    |> refute_issues()
  end
end
