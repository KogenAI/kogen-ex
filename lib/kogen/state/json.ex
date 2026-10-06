defmodule Kogen.State.Json do
  @moduledoc false

  alias Kogen.Contracts.JSON
  alias Kogen.State.Approval
  alias Kogen.State.ApprovalBaselineCodec
  alias Kogen.State.Event
  alias Kogen.State.Run
  alias Kogen.State.Run.Landing

  @approval_trailers [
    {"Kogen-Approval", :approval},
    {"Kogen-Approved-By", :approved_by},
    {"Kogen-Approved-Hash", :approved_hash},
    {"Kogen-Approved-At", :approved_at},
    {"Kogen-Run", :run}
  ]

  # Journal keys match the Event struct fields.
  @event_field_names ~w(
    event recipe roles escalation model_fallback attempt trigger summary findings gate_summary timing stop phase
    name stage class reason detail path declared_domains test_ids seed status result
    approval_commit approved_by base_sha ledger receipts candidate_diff excluded_paths
    red_checks acceptance_items model effort started_at finished_at tokens wall_ms setup_key
    saved_wall_ms credential_source credential_label commit metrics branch item verdict rung
    outcomes attempts failing experimental matrix generated kept repair
  )a
  @event_fields Enum.map(@event_field_names, &{&1, Atom.to_string(&1)})

  def acceptance_items(rows), do: Enum.map(rows, &{Map.fetch!(&1, "id"), Map.get(&1, "status")})

  def acceptance_ledger(rows) do
    rows
    |> Enum.filter(&(&1 |> Map.fetch!("tag") |> String.split("/") |> length() == 2))
    |> Enum.group_by(&(&1 |> Map.fetch!("tag") |> String.split("/") |> List.last()))
    |> Map.new(fn {id, tests} ->
      {id, if(Enum.all?(tests, &(Map.fetch!(&1, "status") == "passed")), do: "passed")}
    end)
  end

  @spec encode_approval(Approval.t()) :: {:ok, binary()} | {:error, :invalid_json_value}
  def encode_approval(%Approval{} = approval) do
    encode(%{
      schema: 1,
      slug: approval.slug,
      intent_sha256: approval.intent_sha256,
      target_branch: approval.target_branch,
      base_sha: approval.base_sha,
      domains: approval.domains,
      acceptance_paths: approval.acceptance_files |> Map.keys() |> Enum.sort(),
      protected_manifest: approval.protected_manifest,
      check_baseline: ApprovalBaselineCodec.encode(approval.check_baseline),
      by: approval.by,
      at: DateTime.to_iso8601(approval.at)
    })
  end

  @spec decode_approval(binary(), String.t()) ::
          {:ok, Approval.t(), [String.t()]} | {:error, atom()}
  def decode_approval(binary, slug) when is_binary(binary) and is_binary(slug) do
    with {:ok, json} <- decode_object(binary) do
      approval_from_json(json, slug)
    end
  end

  @spec encode_run(Run.t()) :: {:ok, binary()} | {:error, :invalid_json_value}
  def encode_run(%Run{} = run) do
    encode(%{
      schema: 1,
      run_id: run.id,
      slug: run.slug,
      intent_sha256: run.intent_sha256,
      target_branch: run.target_branch,
      approval_commit: run.approval_commit,
      status: run.status,
      landing: landing_fields(run.landing),
      owner_os_pid: run.owner_os_pid
    })
  end

  @spec decode_run(binary(), Path.t()) :: {:ok, Run.t()} | {:error, atom()}
  def decode_run(binary, dir) when is_binary(binary) and is_binary(dir) do
    with {:ok, json} <- decode_object(binary) do
      run_from_json(json, dir)
    end
  end

  @spec encode_event(map()) :: {:ok, binary()} | {:error, :invalid_json_value}
  def encode_event(event) when is_map(event), do: encode(event)

  @spec decode_event(binary()) :: {:ok, Event.t()} | {:error, :invalid_event}
  def decode_event(binary) when is_binary(binary) do
    with {:ok, value} <- decode_object(binary),
         {:ok, event} <- event_from_json(value) do
      {:ok, event}
    else
      _invalid -> {:error, :invalid_event}
    end
  rescue
    ArgumentError -> {:error, :invalid_event}
  end

  @doc "A request-journal line of a successful request as a `model_stage` event; any other line is not usage."
  @spec decode_request(binary()) :: {:ok, Event.t()} | :skip
  def decode_request(binary) when is_binary(binary) do
    case decode_object(binary) do
      {:ok, %{"outcome" => "ok", "tokens" => %{}} = json} ->
        case event_from_json(Map.put(json, "event", "model_stage")) do
          {:ok, event} -> {:ok, event}
          {:error, :invalid_event} -> :skip
        end

      _not_usage ->
        :skip
    end
  rescue
    ArgumentError -> :skip
  end

  @spec approval_message(Approval.t()) :: String.t()
  def approval_message(%Approval{} = approval) do
    trailers = [
      approval: approval.slug,
      approved_by: approval.by,
      approved_hash: approval.intent_sha256,
      approved_at: DateTime.to_iso8601(approval.at)
    ]

    "Kogen immutable approval package\n\n" <> render_trailers(trailers)
  end

  @spec verify_approval_trailers(String.t(), Approval.t()) ::
          :ok | {:error, :approval_trailer_mismatch}
  def verify_approval_trailers(message, %Approval{} = approval) when is_binary(message) do
    expected = [
      approval: approval.slug,
      approved_by: approval.by,
      approved_hash: approval.intent_sha256,
      approved_at: DateTime.to_iso8601(approval.at)
    ]

    trailers = parse_trailers(message)

    if Enum.all?(expected, fn {key, value} -> Keyword.get(trailers, key) == value end),
      do: :ok,
      else: {:error, :approval_trailer_mismatch}
  end

  @spec claim_message(String.t()) :: String.t()
  def claim_message(run_id) when is_binary(run_id),
    do: "Kogen project claim\n\n" <> render_trailers(run: run_id)

  @spec claim_run_id(String.t()) :: String.t() | nil
  def claim_run_id(message) when is_binary(message),
    do: Keyword.get(parse_trailers(message), :run)

  defp approval_from_json(json, slug) do
    with 1 <- Map.get(json, "schema"),
         ^slug <- Map.get(json, "slug"),
         hash when is_binary(hash) <- Map.get(json, "intent_sha256"),
         branch when is_binary(branch) <- Map.get(json, "target_branch"),
         base when is_binary(base) <- Map.get(json, "base_sha"),
         domains when is_list(domains) <- Map.get(json, "domains"),
         paths when is_list(paths) <- Map.get(json, "acceptance_paths"),
         manifest when is_map(manifest) <- Map.get(json, "protected_manifest"),
         {:ok, check_baseline} <-
           ApprovalBaselineCodec.decode(Map.get(json, "check_baseline", [])),
         by when is_binary(by) <- Map.get(json, "by"),
         at_text when is_binary(at_text) <- Map.get(json, "at"),
         {:ok, at, _offset} <- DateTime.from_iso8601(at_text),
         true <- Enum.all?(domains, &is_binary/1),
         true <- Enum.all?(paths, &valid_approval_path?(&1, slug)),
         true <-
           Enum.all?(manifest, fn {path, digest} -> is_binary(path) and is_binary(digest) end) do
      approval = %Approval{
        slug: slug,
        intent_bytes: <<>>,
        intent_sha256: hash,
        target_branch: branch,
        base_sha: base,
        domains: domains,
        acceptance_files: %{},
        protected_manifest: manifest,
        check_baseline: check_baseline,
        by: by,
        at: at
      }

      {:ok, approval, paths}
    else
      _invalid -> {:error, :invalid_approval}
    end
  end

  defp run_from_json(json, dir) do
    with 1 <- Map.get(json, "schema"),
         id when is_binary(id) <- Map.get(json, "run_id"),
         :ok <- valid_run_id(id),
         slug when is_binary(slug) <- Map.get(json, "slug"),
         hash when is_binary(hash) <- Map.get(json, "intent_sha256"),
         branch when is_binary(branch) <- Map.get(json, "target_branch"),
         {:ok, status} <- run_status(Map.get(json, "status")),
         {:ok, approval_commit} <- nullable_string(Map.get(json, "approval_commit")),
         {:ok, landing} <- landing_from_json(Map.get(json, "landing"), id),
         {:ok, owner_os_pid} <- nullable_pid(Map.get(json, "owner_os_pid")) do
      {:ok,
       %Run{
         id: id,
         dir: dir,
         slug: slug,
         intent_sha256: hash,
         target_branch: branch,
         approval_commit: approval_commit,
         status: status,
         landing: landing,
         owner_os_pid: owner_os_pid
       }}
    else
      _invalid -> {:error, :invalid_run}
    end
  end

  defp event_from_json(json) do
    values = Enum.reduce(@event_fields, %{}, &event_field(json, &1, &2))

    if is_binary(values.event),
      do: {:ok, struct!(Event, values)},
      else: {:error, :invalid_event}
  end

  defp event_field(json, {field, key}, values), do: Map.put(values, field, Map.get(json, key))

  defp landing_from_json(:null, _run_id), do: {:ok, nil}

  defp landing_from_json(json, run_id) when is_map(json) do
    values = %{
      approval_commit: Map.get(json, "approval_commit"),
      run_id: Map.get(json, "run_id"),
      expected_parent: Map.get(json, "expected_parent"),
      final_tree: Map.get(json, "final_tree"),
      candidate_commit: Map.get(json, "candidate_commit")
    }

    if values.run_id == run_id and Enum.all?(Map.values(values), &valid_identity_value?/1),
      do: {:ok, struct!(Landing, values)},
      else: {:error, :invalid_run}
  end

  defp landing_from_json(_json, _run_id), do: {:error, :invalid_run}

  defp landing_fields(nil), do: nil

  defp landing_fields(%Landing{} = landing) do
    %{
      approval_commit: landing.approval_commit,
      run_id: landing.run_id,
      expected_parent: landing.expected_parent,
      final_tree: landing.final_tree,
      candidate_commit: landing.candidate_commit
    }
  end

  defp run_status("running"), do: {:ok, :running}
  defp run_status("landed"), do: {:ok, :landed}
  defp run_status("failed"), do: {:ok, :failed}
  defp run_status("parked"), do: {:ok, :parked}
  defp run_status(_status), do: {:error, :invalid_run}

  defp nullable_string(:null), do: {:ok, nil}
  defp nullable_string(value) when is_binary(value), do: {:ok, value}
  defp nullable_string(_value), do: {:error, :invalid_run}

  defp nullable_pid(nil), do: {:ok, nil}
  defp nullable_pid(:null), do: {:ok, nil}
  defp nullable_pid(pid) when is_integer(pid) and pid > 0, do: {:ok, pid}
  defp nullable_pid(_pid), do: {:error, :invalid_run}

  defp valid_run_id(id) do
    if Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/, id),
      do: :ok,
      else: {:error, :invalid_run_id}
  end

  defp valid_identity_value?(value), do: is_binary(value) and value != ""

  defp valid_approval_path?(path, slug) do
    safe_repo_path?(path) and path not in [intent_path(slug), approval_path(slug)]
  end

  defp safe_repo_path?(path) when is_binary(path) do
    parts = String.split(path, "/")

    Path.type(path) == :relative and path != "" and
      Enum.all?(parts, &(&1 not in ["", ".", "..", ".git"]))
  end

  defp safe_repo_path?(_path), do: false

  defp intent_path(slug), do: ".kogen/intents/#{slug}/intent.md"
  defp approval_path(slug), do: ".kogen/intents/#{slug}/approval.json"

  defp render_trailers(trailers) do
    Enum.map_join(trailers, "\n", fn {key, value} -> "#{trailer_name(key)}: #{value}" end)
  end

  defp parse_trailers(message) do
    message
    |> String.split("\n")
    |> Enum.reduce([], fn line, trailers ->
      case String.split(line, ": ", parts: 2) do
        [name, value] -> put_trailer(trailers, name, value)
        _other -> trailers
      end
    end)
  end

  defp put_trailer(trailers, name, value) do
    case Enum.find(@approval_trailers, fn {trailer, _key} -> trailer == name end) do
      {_trailer, key} -> Keyword.put(trailers, key, value)
      nil -> trailers
    end
  end

  defp trailer_name(:approval), do: "Kogen-Approval"
  defp trailer_name(:approved_by), do: "Kogen-Approved-By"
  defp trailer_name(:approved_hash), do: "Kogen-Approved-Hash"
  defp trailer_name(:approved_at), do: "Kogen-Approved-At"
  defp trailer_name(:run), do: "Kogen-Run"

  defp decode_object(binary) do
    case JSON.decode(binary) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _other -> {:error, :invalid_json}
    end
  end

  defp encode(value) do
    with {:ok, normalized} <- normalize(value) do
      {:ok, normalized |> :json.encode() |> IO.iodata_to_binary()}
    end
  rescue
    ArgumentError -> {:error, :invalid_json_value}
  end

  defp normalize(nil), do: {:ok, :null}
  defp normalize(true), do: {:ok, true}
  defp normalize(false), do: {:ok, false}
  defp normalize(value) when is_integer(value) or is_float(value), do: {:ok, value}
  defp normalize(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}

  defp normalize(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: {:ok, %{base64: Base.encode64(value)}}
  end

  defp normalize(value) when is_list(value), do: normalize_list(value, [])

  defp normalize(value) when is_tuple(value) do
    with {:ok, items} <- normalize(Tuple.to_list(value)), do: {:ok, %{tuple: items}}
  end

  defp normalize(value) when is_struct(value), do: value |> Map.from_struct() |> normalize()

  defp normalize(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, result} ->
      with {:ok, json_key} <- normalize_key(key),
           {:ok, json_item} <- normalize(item) do
        {:cont, {:ok, Map.put(result, json_key, json_item)}}
      else
        :error -> {:halt, {:error, :invalid_json_value}}
      end
    end)
  end

  defp normalize(_value), do: {:error, :invalid_json_value}

  defp normalize_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_list([value | rest], acc) do
    case normalize(value) do
      {:ok, normalized} -> normalize_list(rest, [normalized | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(_key), do: :error
end
