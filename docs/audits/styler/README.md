Styler adoption evidence

Run from this worktree with Elixir 1.20.4:

```
mise exec -- mix run docs/audits/styler/evidence.exs
```

The script expands the actual `.formatter.exs` inputs, reads only those repository
files, and formats each twice with Styler 1.12.2 and `on_error: :raise`. It writes a
JSON report with input/first/second digests, parse results, byte preservation and
metadata-free AST comparisons. It does not change the audited inputs. The `results/`
directory is the retained local run; rerunning after later changes refreshes that
snapshot. A changed AST is a request for semantic review, not a blocking finding.

Executable examples compare return values and exception types for listed input
domains. Numeric separators, map construction and redundant tagged `with` results
are safe in those exercised domains. The binding-order example preserves the outer
binding and error branch. DateTime microseconds exercise cases fixed in the pin,
including zero and six-digit input precision and the piped form.

Strict boolean `case`, strict `with true`, and duplicate config ordering are separate
correctness counterexamples. Each has retained input, first-pass and second-pass
source plus observed results. They demonstrate why idempotence alone cannot prove a
rewrite safe. Taste-only formatting is never classified as a correctness error.
We do not execute arbitrary repository modules to infer semantic equivalence: byte
preservation establishes the current real inputs are unchanged, while examples
establish only the explicitly tested domains.

The upstream opt-in design, supported-rule proposal, reproductions and expected
behavior are in [the local draft](upstream-draft.md). The proposed API is not shipped
in Styler 1.12.2. No fork, gate policy change, issue filing or PR publication is part
of this task.
