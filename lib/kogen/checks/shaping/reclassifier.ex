defmodule Kogen.Checks.Shaping.Reclassifier do
  @moduledoc false

  alias Kogen.Checks.LedgerRow
  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.Intent
  alias Kogen.Contracts.ShapeWarning

  @spec run(Intent.t(), Path.t(), [LedgerRow.t()], Path.t()) ::
          {:ok, Intent.t(), [ShapeWarning.t()]} | {:error, Failure.t()}
  def run(%Intent{} = intent, workdir, rows, run_dir) do
    with {:ok, updated_intent, warnings} <- reclassify_red_keeps(intent, rows, workdir),
         :ok <- require_change_item(updated_intent, rows, run_dir) do
      {:ok, updated_intent, warnings}
    end
  end

  defp reclassify_red_keeps(intent, rows, workdir) do
    red_ids =
      intent.acceptance
      |> Enum.filter(&(&1.verify == :test_keep))
      |> Enum.filter(fn item ->
        Enum.any?(rows, fn row ->
          row.tag == "#{intent.slug}/#{item.id}" and row.status == :failed
        end)
      end)
      |> Enum.map(& &1.id)

    case red_ids do
      [] -> {:ok, intent, []}
      ids -> rewrite_intent(intent, ids, workdir)
    end
  end

  defp rewrite_intent(intent, ids, workdir) do
    path = intent_path(intent, workdir)

    with {:ok, source} <- File.read(path),
         {:ok, rewritten} <- rewrite_verify_lines(source, intent.acceptance, ids),
         :ok <- File.write(path, rewritten, [:binary]) do
      acceptance =
        Enum.map(intent.acceptance, fn item ->
          if item.id in ids, do: %{item | verify: :test}, else: item
        end)

      warning = %ShapeWarning{
        code: :shape_reclassified,
        item_ids: ids,
        message:
          "#{Enum.join(ids, ", ")} changed from test keep to test because the acceptance test is red on the base."
      }

      {:ok, %{intent | acceptance: acceptance}, [warning]}
    else
      {:error, %Failure{} = failure} ->
        {:error, failure}

      {:error, reason} ->
        {:error,
         failure(
           :environment,
           :intent_rewrite_failed,
           "Could not update Verify lines: #{inspect(reason)}"
         )}
    end
  end

  defp intent_path(%Intent{path: path}, workdir) do
    if Path.type(path) == :absolute, do: path, else: Path.join(workdir, path)
  end

  defp rewrite_verify_lines(source, acceptance, ids) do
    lines = String.split(source, "\n", trim: false)

    acceptance
    |> Enum.filter(&(&1.id in ids))
    |> Enum.reduce_while({:ok, lines}, fn item, {:ok, current_lines} ->
      case rewrite_verify_line(current_lines, item.id) do
        {:ok, next_lines} -> {:cont, {:ok, next_lines}}
        {:error, %Failure{} = failure} -> {:halt, {:error, failure}}
      end
    end)
    |> case do
      {:ok, rewritten_lines} -> {:ok, Enum.join(rewritten_lines, "\n")}
      error -> error
    end
  end

  defp rewrite_verify_line(lines, id) do
    pattern = Regex.compile!("\\A(\\s*-\\s*#{Regex.escape(id)}:\\s*)test keep(?=\\s|$)")

    case Enum.find_index(lines, &Regex.match?(pattern, &1)) do
      index when is_integer(index) ->
        replace_verify_kind(lines, index, id, pattern)

      nil ->
        {:error,
         failure(:controller, :intent_rewrite_failed, "Verify line for #{id} is missing.")}
    end
  end

  defp replace_verify_kind(lines, index, id, pattern) do
    line = Enum.at(lines, index)

    case Regex.run(pattern, line, capture: :all_but_first) do
      [prefix] ->
        updated = Regex.replace(pattern, line, prefix <> "test", global: false)
        {:ok, List.replace_at(lines, index, updated)}

      _no_match ->
        {:error,
         failure(
           :controller,
           :intent_rewrite_failed,
           "Verify line for #{id} no longer has the parsed `test keep` form."
         )}
    end
  end

  defp require_change_item(intent, rows, run_dir) do
    if Enum.all?(intent.acceptance, &(&1.verify == :test_keep)) do
      tests =
        rows
        |> Enum.filter(&String.starts_with?(&1.tag, intent.slug <> "/"))
        |> Enum.map_join("", &"Acceptance test: #{&1.test} [#{&1.tag}]\n")

      output = first_output_lines(Path.join([run_dir, "logs", "acceptance.log"]))

      {:error,
       failure(
         :candidate,
         :all_items_keep,
         "Every acceptance item is marked `test keep`; at least one item must verify behavior absent from the base.\n" <>
           tests <> "Output (first 20 lines):\n" <> output
       )}
    else
      :ok
    end
  end

  defp first_output_lines(path) do
    case File.read(path) do
      {:ok, contents} ->
        output = contents |> String.split("\n", trim: false) |> Enum.take(20) |> Enum.join("\n")
        if String.trim(output) == "", do: "(no output captured)", else: output

      {:error, _reason} ->
        "(acceptance output log unavailable)"
    end
  end

  defp failure(class, reason, detail), do: %Failure{class: class, reason: reason, detail: detail}
end
