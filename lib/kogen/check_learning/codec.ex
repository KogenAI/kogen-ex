defmodule Kogen.CheckLearning.Proposal do
  @moduledoc false
  defstruct [:id, :family, :target, :observed_failure, :status, observations: []]
  @type t :: %__MODULE__{}
end

defmodule Kogen.CheckLearning.Spec do
  @moduledoc false
  defstruct [:argv, :rule_path, :feedback, :planted_bad, :valid_examples, :real_examples]
  @type t :: %__MODULE__{}
end

defmodule Kogen.CheckLearning.Codec do
  @moduledoc false
  alias Kogen.CheckLearning.Proposal
  alias Kogen.CheckLearning.Spec
  alias Kogen.CheckLearning.Store

  @spec read_proposal(Path.t()) :: {:ok, Proposal.t() | nil} | {:error, term()}
  def read_proposal(path) do
    case File.read(path) do
      {:ok, bytes} -> decode_proposal(bytes)
      {:error, :enoent} -> {:ok, nil}
      error -> error
    end
  end

  defp decode_proposal(bytes) do
    with {:ok,
          %{
            "schema" => 1,
            "id" => id,
            "family" => family,
            "target" => target,
            "observed_failure" => failure,
            "status" => status,
            "observations" => observations
          }} <- JSON.decode(bytes),
         true <- family in ["model_quality", "human_style"],
         true <- target == target(family),
         true <-
           is_binary(id) and is_binary(failure) and is_list(observations) and
             Enum.all?(observations, &valid_observation?/1) do
      {:ok,
       %Proposal{
         id: id,
         family: family,
         target: target,
         observed_failure: failure,
         status: status,
         observations: Enum.map(observations, &observation/1)
       }}
    else
      _invalid -> {:error, :invalid_check_proposal}
    end
  end

  defp valid_observation?(row) when is_map(row),
    do: nonempty?(row["key"]) and nonempty?(row["build_id"])

  defp valid_observation?(_row), do: false

  defp observation(row) do
    %{
      key: row["key"],
      build_id: row["build_id"],
      attempt: row["attempt"],
      model: row["model"],
      stage: row["stage"],
      failure: row["failure"],
      detail: row["detail"],
      model_wall_ms: row["model_wall_ms"],
      repairs: row["repairs"],
      journal: row["journal"],
      examples: row["examples"]
    }
  end

  @spec qualification_identity(binary()) :: {:ok, map()} | {:error, term()}
  def qualification_identity(bytes) do
    case JSON.decode(bytes) do
      {:ok, %{"schema" => 1, "proposal_id" => id, "rule_sha256" => rule, "target" => target}} ->
        {:ok, %{proposal_id: id, rule_sha256: rule, target: target}}

      _invalid ->
        {:error, :invalid_check_qualification}
    end
  end

  @spec read_spec(Path.t()) :: {:ok, Spec.t()} | {:error, term()}
  def read_spec(path) do
    with {:ok, bytes} <- File.read(path), {:ok, data} <- JSON.decode(bytes), do: spec(data)
  end

  defp spec(%{
         "argv" => argv,
         "rule_path" => rule,
         "feedback" => feedback,
         "planted_bad" => bad,
         "valid_examples" => valid,
         "real_examples" => real
       }) do
    if strings?(argv) and Enum.any?(argv, &String.contains?(&1, "{path}")) and
         Store.safe_path?(rule) and nonempty?(feedback) and nonempty?(bad) and
         strings?(valid) and length(valid) >= 2 and real_examples?(real) do
      cases = Enum.map(real, fn row -> %{path: row["path"], expected: row["expected"]} end)

      {:ok,
       %Spec{
         argv: argv,
         rule_path: rule,
         feedback: feedback,
         planted_bad: bad,
         valid_examples: valid,
         real_examples: cases
       }}
    else
      {:error, :invalid_precision_spec}
    end
  end

  defp spec(_data), do: {:error, :invalid_precision_spec}

  defp real_examples?(rows) when is_list(rows) and length(rows) >= 3 do
    valid =
      Enum.all?(rows, fn
        %{"path" => path, "expected" => expected} ->
          Store.safe_path?(path) and expected in ["bad", "valid"]

        _row ->
          false
      end)

    valid and length(Enum.uniq_by(rows, & &1["path"])) == length(rows) and
      Enum.any?(rows, &(&1["expected"] == "bad")) and
      Enum.any?(rows, &(&1["expected"] == "valid"))
  end

  defp real_examples?(_rows), do: false
  defp strings?(items), do: is_list(items) and items != [] and Enum.all?(items, &nonempty?/1)
  defp nonempty?(text), do: is_binary(text) and String.trim(text) != ""
  defp target("human_style"), do: "optimum_credo"
  defp target("model_quality"), do: "kogen_credo"
end
