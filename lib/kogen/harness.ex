defmodule Kogen.Harness do
  @moduledoc "Runs Kogen's provider-backed shaping, Developer, context, plan, and review stages."
  use Boundary,
    deps: [
      Kogen.Flakes,
      Kogen.Quality,
      Kogen.Checks,
      Kogen.Contracts,
      Kogen.Proc,
      Kogen.Provider,
      Kogen.Project,
      Kogen.Resilience,
      Kogen.Tooling
    ],
    exports: [Opts, Pack, Plan, Review, Result, ShapePass, ShapeCall, PhaseTiming]

  alias Kogen.Contracts.RolePrompt
  alias Kogen.Harness.Developer
  alias Kogen.Harness.OneShot
  alias Kogen.Harness.Opts
  alias Kogen.Harness.Pack
  alias Kogen.Harness.Plan
  alias Kogen.Harness.Result
  alias Kogen.Harness.Review
  alias Kogen.Harness.ShapePass
  alias Kogen.Harness.Shaping
  alias Kogen.Harness.Stages
  alias Kogen.Tooling.Error

  @spec context_pack(Opts.t(), String.t()) :: {:ok, Pack.t()} | {:error, term()}
  def context_pack(%Opts{} = opts, intent_text), do: Stages.context_pack(opts, intent_text)

  @spec plan(Opts.t(), Pack.t() | nil, String.t()) :: {:ok, Plan.t()} | {:error, term()}
  def plan(%Opts{} = opts, pack, intent_text) when is_nil(pack) or is_struct(pack, Pack),
    do: Stages.plan(opts, pack, intent_text)

  @spec develop(Opts.t(), String.t(), Plan.t() | nil, map() | nil) ::
          {:ok, Result.t()} | {:error, term()}
  def develop(%Opts{} = opts, intent_text, plan, resume),
    do: develop(opts, intent_text, plan, resume, opts.repairs_left)

  @spec develop(Opts.t(), String.t(), Plan.t() | nil, map() | nil, non_neg_integer()) ::
          {:ok, Result.t()} | {:error, term()}
  def develop(%Opts{} = opts, intent_text, plan, resume, repairs_left)
      when is_integer(repairs_left) and repairs_left >= 0 do
    Developer.run(%{opts | repairs_left: repairs_left}, intent_text, plan, resume)
  end

  def develop(%Opts{}, _intent_text, _plan, _resume, _repairs_left),
    do:
      {:error,
       %Error{reason: :invalid_repair_count, detail: "repairs_left must be non-negative."}}

  @spec review(Opts.t(), String.t(), String.t(), map()) ::
          {:ok, Review.t()} | {:error, term()}
  def review(%Opts{} = opts, intent_text, diff, check_summary),
    do: Stages.review(opts, intent_text, diff, check_summary)

  @doc "One no-tool request on the requested model role."
  @spec ask(Opts.t(), RolePrompt.t()) ::
          {:ok, %{text: String.t(), usage: map()}} | {:error, term()}
  def ask(%Opts{} = opts, %RolePrompt{} = request), do: OneShot.ask(opts, request)

  @spec shape(Opts.t(), String.t(), String.t(), [map()], String.t() | nil, non_neg_integer()) ::
          {:ok, ShapePass.t()} | {:error, term()}
  def shape(%Opts{} = opts, slug, task, history, failure_text, turn_offset),
    do: Shaping.run(opts, slug, task, history, failure_text, turn_offset)
end
