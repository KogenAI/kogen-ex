defmodule Kogen.Kernel.CLI.Runner do
  @moduledoc false

  alias Kogen.Cli.Args
  alias Kogen.Contracts.Failure
  alias Kogen.Engine.Build.Result
  alias Kogen.Kernel.Approval
  alias Kogen.Kernel.CLI.ErrorOutput
  alias Kogen.Kernel.CLI.IntentRemoval
  alias Kogen.Kernel.CLI.ShapeJson
  alias Kogen.Kernel.CLI.StatusOutput
  alias Kogen.Kernel.CLI.TaskInput
  alias Kogen.Kernel.Types.ApprovalPreview
  alias Kogen.Kernel.Types.BuildOptions

  @spec run(Args.t()) :: {non_neg_integer(), String.t()}
  def run(%Args{command: :version} = args), do: version(args)
  def run(%Args{command: :intent_check} = args), do: intent_check(args)
  def run(%Args{command: :intent_shape} = args), do: intent_shape(args)
  def run(%Args{command: :intent_approve} = args), do: approve(args)
  def run(%Args{command: :intent_remove} = args), do: IntentRemoval.run(args)
  def run(%Args{command: :build} = args), do: build(args)
  def run(%Args{command: :build_show} = args), do: build_show(args)
  def run(%Args{command: :status} = args), do: status(args)
  def run(%Args{command: :reconcile} = args), do: reconcile(args)
  def run(%Args{command: :provider_list}), do: provider_list()
  def run(%Args{command: :provider_login} = args), do: provider_login(args)
  def run(%Args{command: :provider_logout} = args), do: provider_logout(args)

  defp version(%Args{project: nil}), do: {0, "kogen #{Kogen.Kernel.version()}\n"}

  defp version(args) do
    case project_directory(args) do
      :ok -> {0, "kogen #{Kogen.Kernel.version()}\n"}
      {:error, reason} -> command_error(reason)
    end
  end

  defp intent_check(args) do
    with :ok <- project_directory(args),
         path = intent_path(hd(args.positionals), args.project),
         {:ok, intent} <- Kogen.Kernel.intent_check(path) do
      {0, "intent #{intent.slug}: valid (sha256 #{intent.sha256})\n"}
    else
      {:error, {:parse, issues}} -> {2, format_issues("parse", issues)}
      {:error, {:lint, issues}} -> {2, format_issues("lint", issues)}
      {:error, reason} -> command_error(reason)
    end
  end

  defp intent_shape(args) do
    with :ok <- project_directory(args),
         {:ok, task} <- TaskInput.read(args.task_file),
         {:ok, result} <-
           Kogen.Kernel.shape(
             hd(args.positionals),
             args.project,
             task
           ) do
      render_shape(result, args.json)
    else
      {:error, {:task_input_unavailable, source, reason}} ->
        {2, "task input unavailable #{source}: #{inspect(reason)}\n"}

      {:error, reason} ->
        command_error(reason)
    end
  end

  defp render_shape(result, true) do
    {0, ShapeJson.encode(result) <> "\n"}
  end

  defp render_shape(result, false) do
    calls = Enum.map_join(result.calls, "", &shape_call_text/1)
    warnings = Approval.warnings_text(result.warnings)

    {0,
     "Intent: #{result.intent_path}\nAcceptance test: #{result.acceptance_path}\n" <>
       "Validated after #{result.rounds} round(s).\n" <>
       warnings <>
       calls <>
       "Transcript: #{result.transcript_path}\n"}
  end

  defp shape_call_text(call) do
    tokens = call.tokens

    "shape #{call.model}/#{call.effort} input=#{tokens.input} cached=#{tokens.cached_input} " <>
      "output=#{tokens.output} reasoning=#{tokens.reasoning} wall_ms=#{call.wall_ms}\n"
  end

  defp approve(args) do
    with :ok <- project_directory(args),
         {:ok, preview} <-
           Kogen.Kernel.approval_preview(
             hd(args.positionals),
             args.project,
             args.origin,
             args.base,
             args.by
           ) do
      confirm_approval(preview, args.yes)
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp confirm_approval(%ApprovalPreview{} = preview, true) do
    case Kogen.Kernel.approve(preview) do
      {:ok, sha} -> {0, approval_screen(preview) <> "approved: #{sha}\n"}
      {:error, reason} -> command_error(reason)
    end
  end

  defp confirm_approval(%ApprovalPreview{} = preview, false) do
    screen = approval_screen(preview)
    IO.write(screen)

    case tty_confirmation() do
      :yes ->
        case Kogen.Kernel.approve(preview) do
          {:ok, sha} -> {0, "approved: #{sha}\n"}
          {:error, reason} -> command_error(reason)
        end

      :no ->
        {1, "approval declined\n"}

      :unavailable ->
        {2, "approval requires a TTY; pass --yes to approve explicitly\n"}
    end
  end

  defp build(args) do
    with :ok <- project_directory(args),
         {:ok, %Result{} = result} <-
           Kogen.Kernel.build(%BuildOptions{
             slug: hd(args.positionals),
             project_root: args.project,
             origin: args.origin,
             base: args.base
           }) do
      render_build(result)
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp render_build(%Result{status: :landed} = result) do
    {0, format_build(result)}
  end

  defp render_build(%Result{} = result) do
    code = failure_code(result.failure)
    repair = repair_guidance(result.failure)
    {code, format_build(result) <> repair}
  end

  defp format_build(%Result{} = result) do
    lines = Enum.map_join(result.lines, "\n", & &1)
    "run: #{result.run_id}\n#{lines}\nrun dir: #{result.run_dir}\n"
  end

  defp status(args) do
    with :ok <- project_directory(args),
         {:ok, statuses} <- Kogen.Kernel.status(args.project, args.origin, args.base) do
      output = if args.json, do: StatusOutput.json(statuses), else: StatusOutput.text(statuses)
      {0, output}
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp build_show(args) do
    with :ok <- project_directory(args),
         {:ok, json} <-
           Kogen.Kernel.report(
             hd(args.positionals),
             args.project,
             args.origin,
             args.base
           ) do
      {0, json <> "\n"}
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp reconcile(args) do
    with :ok <- project_directory(args),
         {:ok, result} <-
           Kogen.Kernel.reconcile(
             hd(args.positionals),
             args.project,
             args.origin,
             args.base
           ) do
      {0, "reconcile: #{result}\n"}
    else
      {:error, reason} -> command_error(reason)
    end
  end

  defp provider_list do
    case Kogen.Kernel.provider_list() do
      {:ok, []} -> {0, "chatgpt: not signed in\n"}
      {:ok, lines} -> {0, Enum.join(lines)}
      {:error, reason} -> command_error(reason)
    end
  end

  defp provider_login(args) do
    label = args.account_label || "default"

    case Kogen.Kernel.provider_login(label) do
      {:ok, result} ->
        notice = if result.first_notice?, do: "You're using your ChatGPT plan\n", else: ""
        email = if is_binary(result.email), do: " (#{result.email})", else: ""
        {0, notice <> "chatgpt:#{result.label} signed in#{email}\n"}

      {:error, reason} ->
        command_error(reason)
    end
  end

  defp provider_logout(args) do
    label = args.account_label || "default"

    case Kogen.Kernel.provider_logout(label) do
      {:ok, %{remote_revoked?: true}} ->
        {0, "chatgpt:#{label} signed out\n"}

      {:ok, %{remote_revoked?: false}} ->
        {0,
         "chatgpt:#{label} signed out locally; remote revocation was not confirmed. " <>
           "You can disconnect Kogen in ChatGPT Settings if needed.\n"}

      {:error, reason} ->
        command_error(reason)
    end
  end

  defp approval_screen(preview) do
    intent = preview.intent
    criteria = Enum.map_join(intent.acceptance, "", &acceptance_line/1)
    warnings = Approval.warnings_text(preview.warnings, preview.approval.check_baseline)

    """
    Intent: #{intent.slug} — #{intent.title}
    SHA-256: #{preview.approval.intent_sha256}
    Approved by: #{preview.approval.by}
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

  defp tty_confirmation do
    case File.open("/dev/tty", [:read, :write]) do
      {:ok, device} -> read_confirmation(device)
      {:error, _reason} -> :unavailable
    end
  end

  defp read_confirmation(device) do
    answer = IO.gets(device, "Approve this Intent? [y/N] ")
    File.close(device)
    if is_binary(answer) and String.downcase(String.trim(answer)) == "y", do: :yes, else: :no
  end

  defp format_issues(kind, issues) do
    rows = Enum.map_join(issues, "", &issue_line/1)
    "#{kind} failed:\n#{rows}"
  end

  defp issue_line(%{rule: rule, message: message, line: line}),
    do: "  #{rule} at #{line}: #{message}\n"

  defp issue_line(%{line: line, message: message}), do: "  line #{line}: #{message}\n"

  defp project_directory(%Args{project: project}) do
    if File.dir?(project), do: :ok, else: {:error, {:project_unavailable, project}}
  end

  defp intent_path(value, project) do
    path = Path.expand(value, project)

    if File.regular?(path),
      do: path,
      else: Path.join([project, ".kogen", "intents", value, "intent.md"])
  end

  defp command_error(reason), do: ErrorOutput.format(reason)

  defp failure_code(%Failure{class: :candidate}), do: 1
  defp failure_code(%Failure{class: :environment}), do: 3
  defp failure_code(%Failure{class: :provider}), do: 4
  defp failure_code(%Failure{class: :controller}), do: 70
  defp failure_code(_failure), do: 70

  defp repair_guidance(%Failure{class: :candidate}),
    do: "repair: harness resumes with failure output (maximum 2 repairs)\n"

  defp repair_guidance(%Failure{class: :provider}),
    do: "repair: provider retry limit reached; check credentials or service availability\n"

  defp repair_guidance(_failure), do: ""
end
