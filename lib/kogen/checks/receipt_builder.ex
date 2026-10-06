defmodule Kogen.Checks.ReceiptBuilder do
  @moduledoc false

  alias Kogen.Contracts.CheckSpec
  alias Kogen.Contracts.Receipt

  @spec build(String.t(), CheckSpec.t(), integer(), Path.t()) ::
          {:ok, Receipt.t()} | {:error, atom()}
  def build(tree, %CheckSpec{} = check, exit_status, log_path, assessment \\ %{findings: []}) do
    case File.read(log_path) do
      {:ok, log} ->
        {:ok,
         %Receipt{
           tree: tree,
           check: check.name,
           exit_status: exit_status,
           analysis: analysis(assessment),
           log_sha256: sha256(log),
           at: current_time()
         }}

      {:error, :enoent} ->
        {:error, :missing_log}

      {:error, _reason} ->
        {:error, :log_read_failed}
    end
  end

  defp analysis(assessment) do
    if Enum.any?(assessment.findings, &(&1.rule in ["parse_timeout", "parse_failure"])),
      do: :incomplete,
      else: :complete
  end

  defp sha256(binary), do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower)

  defp current_time do
    {:ok, naive} = NaiveDateTime.from_erl(:calendar.universal_time())
    {:ok, at} = DateTime.from_naive(naive, "Etc/UTC")

    at
  end
end
