defmodule Kogen.Testkit.BuildSeed do
  @moduledoc "Shares one immutable Build seed for the test suite."

  alias Kogen.Testkit.Temp

  def get!(builder) when is_function(builder, 1) do
    agent = ensure_agent!()

    Agent.get_and_update(
      agent,
      fn
        nil ->
          root = Temp.create!()

          try do
            seed = builder.(root)
            {seed, {root, seed}}
          rescue
            exception ->
              File.rm_rf!(root)
              reraise exception, __STACKTRACE__
          end

        {_root, seed} = state ->
          {seed, state}
      end,
      :infinity
    )
  end

  def cleanup! do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      agent ->
        root =
          Agent.get(agent, fn
            nil -> nil
            {root, _seed} -> root
          end)

        Agent.stop(agent)
        if root, do: File.rm_rf!(root)
        :ok
    end
  end

  defp ensure_agent! do
    case Process.whereis(__MODULE__) do
      nil ->
        case Agent.start(fn -> nil end, name: __MODULE__) do
          {:ok, agent} -> agent
          {:error, {:already_started, agent}} -> agent
        end

      agent ->
        agent
    end
  end
end
