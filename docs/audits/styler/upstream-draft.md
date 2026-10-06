Local draft: Credo-config-driven opt-in rewrites in Styler

Publication status: unpublished. Filing an issue or PR requires Almir's explicit
publication approval. No upstream repository or dependency source has been modified.
This is a proposed upstream API and acceptance contract, not an implemented option.

Problem: our pinned Styler 1.12.2 runs every style pass even though Kogen's strict
Credo config enables primarily correctness and domain checks. A taste rewrite is not
a correctness failure. Opt-in should let a repository choose rewrites by its already
reviewed Credo configuration, without maintaining a permanent fork.

Proposed formatter setting:

```elixir
[
  plugins: [Styler],
  styler: [rewrite_policy: {:credo, ".credo.exs", config: "default"}, on_error: :raise]
]
```

Keep existing behavior when `rewrite_policy` is absent. In the new mode, read the
named Credo configuration relative to the formatter file. Only positively enabled,
supported rule mappings may authorize a rewrite. Honor rule parameters and a disabled
rule's precedence. An absent check does not authorize a rewrite. An invalid file,
unknown configuration, contradictory policy, or unsupported parameter fails with a
clear configuration error; it must never fall back to running all rewrites.

Initial narrow mapping for review:

| Credo check | Proposed rewrite | Required protection |
| --- | --- | --- |
| `Readability.LargeNumbers` | Numeric separators | Preserve numeric value and honor configured threshold |
| `Readability.PipeChainStart` | Move a nested first argument into a pipe | Preserve evaluation count and ordering; honor configured exclusions |
| `Refactor.RedundantWithClauseResult` | Remove redundant result wrapping | Preserve failure values, bindings and exceptions |
| `Readability.AliasOrder` | Alias ordering | Preserve alias binding and attribute/use dependencies |

These short names stand for `Credo.Check.<name>`. A module-level style switch is
insufficient: `Blocks` implements several unrelated rules, including boolean rewrites.
Use a per-transformation rule registry and dispatch with explicit immutable policy.
Unmapped transformations (config sorting, alias lifting, pipeline optimizations,
case-to-if, with-to-if, def layout and deprecation migrations) stay off in this mode.
Unsupported custom Credo checks are reported as unmapped, and enable no transformation.
Warnings about unsupported mappings are informational, not correctness findings.

Correctness protections apply even when a mapped check is enabled. A strict boolean
case over an unrestricted value cannot become a truthiness test. A `with true <- value`
without `else` must still return the unmatched value. Duplicate config keys must retain
their last-write order. DateTime microsecond precision must remain intact. The local
`results/` directory contains minimal input, first-pass and second-pass files plus
executable results for each case.

Acceptance examples for an upstream PR:

1. Empty or correctness-only `checks.enabled` leaves all AST rewrites disabled;
   standard Elixir whitespace formatting still runs.
2. Enable only `Readability.LargeNumbers`: `1000000` gets separators; the strict
   boolean case and duplicate config example remain semantically identical.
3. Disable `LargeNumbers` after enabling it: the literal is left alone. A supported
   threshold parameter controls whether the rule applies; unknown params fail clearly.
4. Enable `RedundantWithClauseResult`: exercise tagged success, tagged error, `nil`,
   and nested binding/else branches before and after the rewrite.
5. Format every Kogen formatter input twice. The second pass must equal the first.
   No parse/style exception may be swallowed (`on_error: :raise`).
6. Format project A then B, and B then A, using different rule sets in the same VM.
   Results must depend only on each file's policy. Current `Styler.Config.initialize/1`
   caches process-wide policy; do not extend that cache to project-specific opt-in.
7. Missing Credo file or config, malformed config, and an unreadable file fail with
   actionable errors and perform no rewrite. Never execute config from an unrelated
   project or use the working directory as a hidden fallback.
8. Comment placement, module attribute dependencies, and pipeline evaluation order
   remain stable; test behavioral fixtures as well as formatted golden outputs.

Implementation outline: add a small policy loader, explicit mappings with supported
parameters, and per-rewrite authorization. Split authorization inside shared style
passes rather than duplicating the passes. Resolve the policy once per formatter
configuration and key any cache by its content digest and configuration name. Keep the
all-styles mode backward compatible. Review the minimal mapping before widening it.

Upstream context: the pinned README declines ad hoc rewrite switches. This proposal
uses an existing rule configuration rather than a second taste configuration. The
[strict-with report](https://github.com/adobe/elixir-styler/issues/186) describes an
unmatched-value change; we reproduce it on the pin rather than assume it is resolved.
The pinned changelog records fixes for direct and piped DateTime microsecond rewrites
in 1.12.1/1.12.2; both are executable contrast cases here. Maintainer acceptance remains
an open question. Kogen keeps its dependency pinned while this local draft is reviewed.
