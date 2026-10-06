# Finding records

Compile, Credo, Dialyzer, ExUnit and format adapters retain `tool`, `rule` (null when
unavailable), `severity`, `path`, `line`, `col`, `symbol`, `message`, available `explanation`
and `hint`, and a stable `id`. Missing locations and symbols remain null. File-only format
failures have no invented line or column. Compiler warnings retain warning severity.
Messages, explanations and test names are retained in full in records; text feedback
clips the message, keeps bounded assertion details and the first project frame, adds an
available actionable hint, and puts counts after any changed-code ranges.

IDs exclude line and column. They include the tool and path; ExUnit identity uses the full
module and test name, while other adapters use rule, known symbol and normalized message.
Two tools or two long test names therefore remain distinct when their locations coincide.
Identical unanchored diagnostics cannot be distinguished beyond their available meaning;
records at different locations are still retained. Baseline rule/test comparison also scopes
identity by tool. This does not change the baseline status contract.

The done gate parses the complete captured log when available, then writes every finding
and raw-log link to `gate-findings-<id>.json`. `last_gate.findings_path` in the Build JSON
report links that file. The inline gate summary still shows at most 20 findings, with
complete meaning for each displayed record. Full logs and the full findings file preserve
the rest. ExUnit explanations retain the complete failure block even when assertion
values in the compact message are clipped. Baseline-aware repair and flake evidence
classification retain their existing status contracts.

Diagnostics owns the adapters and rendering, keeping Checks within the domain size limit.
`Kogen.Checks.Feedback` preserves the check-facing interface.
