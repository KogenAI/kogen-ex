# T79 quality gate evidence

## S15 — clone and changed-code advice

Measured on the T79 worktree against `careful-rebuild` (`d8f29faa`), Elixir
1.20.4 / OTP 29.1.1, with the actual ExDNA 1.5.4 and Reach 2.8.4 commands.
The changed-file advisory analysis completed in **20.915 seconds**. ExDNA
reported one new clone between `.credo.exs` and the protected configuration
fixture; Reach completed with no strictness or suppression findings. Neither
tool was skipped. This includes baseline extraction, independent snapshot
creation, copied dependency/build caches, tool startup and report parsing.
Analysis has a shared 24-second process budget (with process teardown overhead).

Behaviour tests use real Git repositories and the real tools. They demonstrate
that uncommitted clones and both field-access and `Map.fetch!` downgrades appear
in gate warnings while the gate passes; generated directories and generated
markers are excluded; existing clones shifted by blank lines are not new;
source files, HEAD and candidate Git status remain unchanged. Separate cases
exercise reasonless blocking, reasoned suppressions, quoted markers, missing
dependencies, unavailable tools and the final verification gate.

Full checks use the repository's `KOGEN_SANDBOXED=1` mode to exclude Keychain
and Seatbelt tests. PLTs and measurement artifacts stay in the worktree's
ignored `_build` directory. No credentials, model calls or external writes are
needed.

## S16 — source checks and precision

The same AST analyzers back the two checks in `tools/kogen_checks` and the
native Elixir gates (including final verification and projects without Credo).
`MissingExternalResource` reports compile-time file reads without a matching
resource declaration. Resolved paths block; unresolved expressions remain
advisory. `RepeatedMapShape` reports public parameters/return values with four
or more atom keys when that key set occurs at least three times across the
project's `lib` and `test` sources. This check is always advisory.

Precision was measured on source-only disposable copies under this worktree's
`_build`, using Elixir 1.20.4. The original Phoenix app was never changed.
Each finding was compared with the rule's expected diagnostic and location.

| Project copy | Natural source files | Natural TP / FP | Planted TP / FP | Negative controls | Measured precision |
| --- | ---: | ---: | ---: | ---: | ---: |
| Kogen T79 | 408 | 0 / 0 | 21 / 0 | 23 | 100% |
| Campfire Phoenix (`hearth`) | 62 | 1 / 0 | 21 / 0 | 23 | 100% |

Precision is `TP / (TP + FP)`. Kogen has no natural positives, so its natural-only
precision is undefined; the stated 100% uses controlled defects in the repository
copy. Phoenix's natural-only precision is 100% (one reviewed finding), and its
combined precision is also 100%. These small samples meet the requested 90%
promotion threshold, rather than establishing a population-wide guarantee.

The natural Phoenix finding is `test/hearth/web_push_test.exs:4`: the module
initializes `@expected` with `Jason.decode!(File.read!("test/fixtures/web_push.json"))`
without declaring that fixture as an external resource. Adding the suggested
declaration in the disposable copy clears the finding.

Controlled positives cover module attributes and bodies, read/read!/stream!,
pipes, literal and composed paths, attribute/variable paths, imports/aliases,
templates, read-mode open!, executed callbacks and nested modules. Negative
controls cover matching resources before/after reads, path normalization,
runtime functions/macros/tests/setup, uninvoked closures/captures/quotes,
non-File aliases, inactive branches, excluded imports and write-only open!.
All case diagnostics are recorded in [precision-results.json](precision-results.json).

The behaviour suite also runs a real Mix CLI fixture: the missing declaration
fails both gates, the declaration makes them pass, and changing only the input
file changes the next `mix run` output without forced recompilation. Repeated
map contracts produce located struct advice while both gates pass. Credo finds
eight advisory map contracts in Kogen and exits successfully under `--strict`.

Repeat the precision measurement from this worktree (the copy step discards
only its disposable `_build/t79-*-copy` directories):

```sh
python3 research/t79/copy_precision_projects.py ~/Areas/Kogen/campfire-phoenix-experiment
ERL_FLAGS='+S 2:2' mise exec -- mix run research/t79/measure_precision.exs
ERL_FLAGS='+S 2:2' mise exec -- mix run research/t79/measure_gate.exs
```

Repeat runs use process-specific baseline, snapshot and log names so separate
Elixir processes can safely reuse the same diagnostic run directory.

With both tasks present, the combined quality analysis took **20.494 seconds**
against `careful-rebuild`, using eight Erlang schedulers for tool subprocesses.
The native source checks reported eight advisory map contracts, ExDNA reported
one new configuration/fixture clone, and Reach completed with no strictness or
suppression findings. Neither optional tool was skipped. The shared 24-second
budget keeps slower runs bounded and reports budget exhaustion as a note.

Focused validation passed eight behaviour tests (two gate/CLI tests and six
Credo adapter tests); `mix credo --strict` passed with the eight advisory map
findings. All domains remain within the 3,000-line limit.
