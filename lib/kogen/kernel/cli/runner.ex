defmodule Kogen.Kernel.CLI.Runner do
  @moduledoc false

  alias Kogen.Cli.Args
  alias Kogen.Cli.Version
  alias Kogen.Kernel.Approval
  alias Kogen.Kernel.CLI.ErrorOutput
  alias Kogen.Kernel.CLI.IntentRemoval
  alias Kogen.Kernel.CLI.QueueCommand
  alias Kogen.Kernel.CLI.StatusCommand
  alias Kogen.Kernel.CLI.TaskInput
  alias Kogen.Kernel.Types.ApprovalPreview

  @spec run(Args.t()) :: {non_neg_integer(), String.t()}
  def run(%Args{command: :version}), do: {0, "kogen #{Version.display(Kogen.Kernel.version())}\n"}

  def run(%Args{command: :status} = args), do: StatusCommand.run(args)
  def run(%Args{command: :intent_shape} = args), do: intent_shape(args)
  def run(%Args{command: :intent_approve} = args), do: approve(args)
  def run(%Args{command: :intent_remove} = args), do: IntentRemoval.run(args)
  def run(%Args{command: :queue_start} = args), do: QueueCommand.start(args)
  def run(%Args{command: :queue_stop} = args), do: QueueCommand.stop(args)
  def run(%Args{command: :provider_list}), do: provider_list()
  def run(%Args{command: :provider_login} = args), do: provider_login(args)
  def run(%Args{command: :provider_logout} = args), do: provider_logout(args)
  def run(%Args{command: :provider_use} = args), do: provider_use(args)

  defp intent_shape(%Args{positionals: [slug, file]} = args) do
    with :ok <- project_directory(args),
         {:ok, task} <- TaskInput.read(file),
         {:ok, result} <- Kogen.Kernel.shape(slug, args.project, task) do
      render_shape(result)
    else
      {:error, reason} -> ErrorOutput.format_shape(reason)
    end
  end

  defp render_shape(result) do
    calls = Enum.map_join(result.calls, "", &shape_call_text/1)
    warnings = Approval.warnings_text(result.warnings)

    {0,
     "Intent: #{result.intent_path}\nAcceptance test: #{result.acceptance_path}\n" <>
       "Validated after #{result.rounds} round(s).\n" <>
       warnings <>
       calls <>
       "Transcript: #{result.transcript_path}\n" <>
       "Next: kogen intent approve #{result.slug}\n"}
  end

  defp shape_call_text(call) do
    tokens = call.tokens

    "shape #{call.model}/#{call.effort} input=#{tokens.input} cached=#{tokens.cached_input} " <>
      "output=#{tokens.output} reasoning=#{tokens.reasoning} wall_ms=#{call.wall_ms}\n"
  end

  defp approve(%Args{positionals: [slug | hash]} = args) do
    with :ok <- project_directory(args),
         {:ok, preview} <-
           Kogen.Kernel.approval_preview(slug, args.project, args.origin, args.base, args.by) do
      decide(preview, hash)
    else
      {:error, reason} -> ErrorOutput.format(reason)
    end
  end

  # Without a hash the caller sees the card and decides; exit 5 is advisory "needs a decision".
  defp decide(%ApprovalPreview{} = preview, []) do
    {5,
     approval_card(preview) <>
       "Approve with:\n  kogen intent approve #{preview.intent.slug} #{short_hash(preview)}\n"}
  end

  defp decide(%ApprovalPreview{} = preview, [prefix]) do
    if String.starts_with?(preview.approval.intent_sha256, prefix) do
      case Kogen.Kernel.approve(preview) do
        {:ok, sha} ->
          warnings = Approval.warnings_text(preview.warnings, preview.approval.check_baseline)

          {0,
           warnings <>
             "approved #{preview.intent.slug} #{short_hash(preview)} " <>
             "(approval #{String.slice(sha, 0, 8)}); it is queued\n" <>
             "Next: kogen queue start (does nothing if the queue is already running)\n"}

        {:error, reason} ->
          ErrorOutput.format(reason)
      end
    else
      {1,
       "intent/hash_mismatch: #{preview.intent.slug} is now #{short_hash(preview)}, not #{prefix}; " <>
         "review it again with kogen intent approve #{preview.intent.slug}\n"}
    end
  end

  defp short_hash(preview), do: String.slice(preview.approval.intent_sha256, 0, 8)

  defp provider_list do
    case Kogen.Kernel.provider_list() do
      {:ok, lines} -> {0, Enum.join(lines)}
      {:error, reason} -> ErrorOutput.format(reason)
    end
  end

  defp provider_login(%Args{positionals: ["chatgpt"]}) do
    label = "default"

    case Kogen.Kernel.provider_login("chatgpt", label) do
      {:ok, result} ->
        notice = if result.first_notice?, do: "You're using your ChatGPT plan\n", else: ""
        email = if is_binary(result.email), do: " (#{result.email})", else: ""
        {0, notice <> "chatgpt:#{result.label} signed in#{email}\n"}

      {:error, reason} ->
        ErrorOutput.format(reason)
    end
  end

  defp provider_login(%Args{positionals: ["grok"]}) do
    label = "default"

    case Kogen.Kernel.provider_login("grok", label) do
      {:ok, result} ->
        email = if is_binary(result.email), do: " (#{result.email})", else: ""
        {0, "grok:#{result.label} signed in#{email}\n"}

      {:error, reason} ->
        ErrorOutput.format(reason)
    end
  end

  defp provider_logout(%Args{positionals: ["chatgpt"]}) do
    label = "default"

    case Kogen.Kernel.provider_logout("chatgpt", label) do
      {:ok, %{remote_revoked?: true}} ->
        {0, "chatgpt:#{label} signed out\n"}

      {:ok, %{remote_revoked?: false}} ->
        {0,
         "chatgpt:#{label} signed out locally; remote revocation was not confirmed. " <>
           "You can disconnect Kogen in ChatGPT Settings if needed.\n"}

      {:error, reason} ->
        ErrorOutput.format(reason)
    end
  end

  defp provider_logout(%Args{positionals: ["grok"]}) do
    label = "default"

    case Kogen.Kernel.provider_logout("grok", label) do
      {:ok, %{remote_revoked?: false}} ->
        {0, "grok:#{label} signed out locally\n"}

      {:ok, %{remote_revoked?: true}} ->
        {0, "grok:#{label} signed out\n"}

      {:error, reason} ->
        ErrorOutput.format(reason)
    end
  end

  defp provider_use(%Args{positionals: [provider]} = args) do
    label = args.account_label

    case Kogen.Kernel.provider_use(provider, label, args.project) do
      :ok when is_nil(args.project) -> {0, "#{provider}:#{label} is the default account\n"}
      :ok -> {0, "#{provider}:#{label} is the account for #{args.project}\n"}
      {:error, reason} -> ErrorOutput.format(reason)
    end
  end

  defp approval_card(preview) do
    intent = preview.intent
    criteria = Enum.map_join(intent.acceptance, "", &acceptance_line/1)
    warnings = Approval.warnings_text(preview.warnings, preview.approval.check_baseline)

    """
    Intent: #{intent.slug} — #{intent.title}
    SHA-256: #{preview.approval.intent_sha256}
    Approver: #{preview.approval.by}
    Base: #{preview.approval.target_branch} at #{preview.approval.base_sha}

    Brief
    #{indent(intent.brief)}

    Acceptance
    #{criteria}
    #{warnings}
    """
  end

  defp acceptance_line(item), do: "  - [#{item.id}] #{item.text} (#{item.verify})\n"

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("  " <> &1))

  defp project_directory(%Args{project: project}) do
    if File.dir?(project), do: :ok, else: {:error, {:project_unavailable, project}}
  end
end
