defmodule Kogen.Kernel.CLI.ErrorOutput do
  @moduledoc false

  alias Kogen.Contracts.Failure
  alias Kogen.Contracts.ProviderError
  alias Kogen.Engine.Runtime

  @doc "Formats a shaping failure; provider errors say that no Intent was written."
  def format_shape(%ProviderError{class: class} = error),
    do: shape_provider_failure(class, format(error))

  def format_shape(%Failure{class: :provider, reason: class} = failure),
    do: shape_provider_failure(class, format(failure))

  def format_shape(reason), do: format(reason)

  defp shape_provider_failure(class, {code, text}) when class in [:login, :usage_limit] do
    {code,
     text <>
       "shape/provider_failed: shaping stopped on a provider error that retrying cannot fix; " <>
       "no Intent was written. Fix the account, then run kogen intent shape again.\n"}
  end

  defp shape_provider_failure(_class, {code, text}) do
    {code,
     text <>
       "shape/provider_failed: shaping stopped on a provider error after its retries; " <>
       "no Intent was written. Run kogen intent shape again, or write the Intent yourself.\n"}
  end

  def format(%Failure{} = failure) do
    {failure_code(failure), "#{failure.class}/#{failure.reason}: #{failure.detail}\n"}
  end

  def format(%ProviderError{class: class, message: message}),
    do: {4, "provider/#{class}: #{message}\n"}

  def format(:mise_missing), do: {3, "environment/mise_missing: mise was not found\n"}

  def format({:toolchain_failed, detail}), do: {3, "environment/toolchain_failed: #{detail}\n"}

  def format(:invalid_toolchain_environment),
    do: {3, "environment/invalid_toolchain_environment: mise returned invalid JSON\n"}

  def format({:script_path_unavailable, reason}),
    do: {3, "environment/script_path_unavailable: #{inspect(reason)}\n"}

  def format(:too_many_script_symlinks),
    do: {3, "environment/too_many_script_symlinks: cannot resolve kogen path\n"}

  def format(:intent_not_approved),
    do: {3, "environment/not_approved: Intent has no approval ref\n"}

  def format(:approval_branch_mismatch),
    do: {3, "environment/approval_branch_mismatch: approval targets another branch\n"}

  def format({:project_unavailable, project}),
    do: {3, "environment/project_unavailable: #{project}\n"}

  def format({:intent_remove_requires_force, state}) do
    reason =
      case state do
        "approved" -> "approved or queued"
        "failed" -> "still has a failed Build approval"
        "parked" -> "still has a parked Build approval"
        _other -> "still has an approval ref"
      end

    {2,
     "intent/remove_requires_force: Intent #{reason}; pass --force to discard the approval and remove its files\n"}
  end

  def format(:intent_is_building),
    do: {2, "intent/remove_blocked: Intent is in an active Build and cannot be removed\n"}

  def format(:intent_not_found), do: {2, "intent/not_found: Intent does not exist\n"}

  def format(:intent_must_be_tracked),
    do:
      {2, "intent/remove_requires_commit: Intent files must be tracked to record their removal\n"}

  def format(:git_identity_unavailable),
    do: {2, "intent/approval_identity_unavailable: configure git user.name and user.email\n"}

  def format({:task_input_unavailable, source, reason}),
    do: {2, "task input unavailable #{source}: #{inspect(reason)}\n"}

  def format({:acceptance_check_failed, name, {:ok, result}}) do
    status = if result.timed_out, do: "timed out", else: "failed"
    detail = "check/acceptance_check_failed: acceptance check #{name} #{status}\n"
    {1, detail <> Runtime.output_tail(result.output_tail)}
  end

  def format({:acceptance_check_failed, name, _}),
    do: {1, "check/acceptance_check_failed: acceptance check #{name} failed\n"}

  def format({:checkout_behind_base, base, paths}) do
    {3,
     "environment/checkout_behind_base: checkout is behind #{base}: #{Enum.join(paths, ", ")} " <>
       "differ; update your checkout first\n"}
  end

  def format({:base_moved, expected, current}),
    do: {3, "environment/base_moved: expected #{expected}, found #{inspect(current)}\n"}

  def format({:lint, issues}) when is_list(issues),
    do: {1, "intent/lint: the Intent needs changes\n" <> Enum.map_join(issues, &issue_line/1)}

  def format(:detach_needs_installed_kogen),
    do:
      {3,
       "environment/detach_unavailable: --detach needs an installed kogen; " <>
         "run kogen queue start in the background instead\n"}

  def format({:queue_detach_failed, output}),
    do:
      {3,
       "environment/queue_detach_failed: the background queue did not start\n" <>
         Runtime.output_tail(output)}

  def format({:invalid_accounts_file, path}),
    do: {3, "environment/invalid_accounts_file: #{path} is not valid; fix or delete it\n"}

  def format({kind, path, reason})
      when kind in [:accounts_file_unreadable, :accounts_file_unwritable],
      do: {3, "environment/#{kind}: #{path}: #{inspect(reason)}\n"}

  def format({kind, reason}) when kind in [:queue_lock_failed, :queue_stop_failed],
    do: {3, "environment/#{kind}: #{inspect(reason)}\n"}

  def format(reason), do: {70, "controller/#{inspect(reason)}\n"}

  defp issue_line(%{rule: rule, message: message, line: line}),
    do: "  #{rule} at line #{line}: #{message}\n"

  defp issue_line(%{line: line, message: message}), do: "  line #{line}: #{message}\n"
  defp issue_line(issue), do: "  #{inspect(issue)}\n"

  defp failure_code(%Failure{class: :candidate}), do: 1
  defp failure_code(%Failure{class: :environment}), do: 3
  defp failure_code(%Failure{class: :provider}), do: 4
  defp failure_code(%Failure{class: :controller}), do: 70
  defp failure_code(_failure), do: 70
end
