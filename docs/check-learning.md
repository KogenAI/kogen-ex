Build review revisions and red repair gates retain advisory check proposals in
`<project-state>/check-proposals/check-<fingerprint>/proposal.json`. A repeated
failure at different repair attempts or Builds moves the proposal from watching
to candidate. Repeated delivery of the same observation is counted once.
Review findings are tracked individually. Line numbers are normalized so moving
an unchanged mistake does not erase recurrence.

The proposal names the failure, expected feedback, candidate source seeds for a
planted bad example, baseline contrasting examples, and the associated Build,
model, journal, repair count and measured model time. The source seeds require
qualification: a baseline implementation is not automatically a valid example
of every new rule. `quality: ` findings route to `kogen_credo`; `style: ` findings
route to `optimum_credo`. Untagged correctness failures default to `kogen_credo`.
Human preferences should use the style tag. Neither package depends on the other.

Author a standalone candidate checker in the target package, then prepare a
sample JSON document in that checkout:

```json
{
  "argv": ["elixir", "candidate_check.exs", "{path}"],
  "rule_path": "candidate_check.exs",
  "feedback": "expected user-facing diagnostic",
  "planted_bad": "defmodule Bad do\n  ...\nend\n",
  "valid_examples": ["valid contrasting source one", "valid contrasting source two"],
  "real_examples": [
    {"path": "lib/first.ex", "expected": "bad"},
    {"path": "lib/second.ex", "expected": "valid"},
    {"path": "lib/third.ex", "expected": "valid"}
  ]
}
```

Use actual source and independently reviewed labels. The three-case minimum is
only a lower bound; choose enough representative cases for the proposed rule.
The standalone checker is copied into a separate checker directory and receives
copied sources; relative writes stay in that directory. It returns 0 for valid code and 1 with the
expected feedback for a finding. Other statuses, timeouts and missing feedback
are errors. It must be standalone and read-only; `{path}` is a sample file, not
a live Candidate. Inputs must be regular files inside the checkout; symlinks
and traversal paths are rejected. Each command has a 30-second bound.

Run `kogen checks sample <proposal.json> <sample.json> --project <package-checkout>`.
It retains every case's source hash, label, verdict, output, command and elapsed
time. `qualification.json` reports real-code TP, FP, FN, errors and precision
separately from planted controls. A draft `adoption-intent.md` is generated only
when the planted bad example is caught, contrasting examples pass, real-code
precision is at least 90%, there is a real true positive and no false negatives
or checker errors. Inconclusive or noisy samples retain evidence and generate
no adoption draft. A checker changed during sampling cannot qualify.

The qualification retains the checker source and hash, proposal snapshot/hash,
source cases, observed Build cost and measured checker cost. The resulting
Intent has `changes_gate: true`; the caller must shape and approve that individual
protected rule in the named package. Mining and sampling never install a gate,
change a live Candidate, or interrupt the approved Build. Status and JSON reports
link to candidate proposals. An evidence-write failure is an advisory journal
event, while the original review or repair ruling remains in force.

After measuring Builds with a proposed check, run:

```text
kogen checks effect <qualification.json> <before-run-dir> <checked-run-dir>
```

Both Builds must be finished and use the same Intent hash. The comparison is
stored beside the qualification, with report and journal hashes, outcomes,
base/model identities, model and phase times, repair counts and their deltas.
These are observed comparisons, not automatic causal claims about saved work.
Keep them with the proposal when revising the rule or deciding whether to adopt it.
