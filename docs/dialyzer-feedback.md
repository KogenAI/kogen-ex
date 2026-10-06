# Dialyzer done-gate feedback

Dialyzer continues to run only as part of the configured done gate. Its developer feedback
separates warnings in changed files, warnings in unchanged files, warnings with unavailable
locations, and known locations whose change scope could not be obtained. Classification is
at file granularity using the controller's changed-path list, not a claim that the warning
line itself was edited.

The summary shows three warnings, prioritizing changed files and preserving tool order
within each group. Each includes its available path and line, rule, message and hint; no
column is invented. When both changed and unchanged files warn, feedback suggests starting
with changed files and explains that unchanged files may be downstream effects of a return
shape change. It does not instruct the builder to edit every downstream file.

If Dialyzer reports more errors than the parser can locate, the remainder is counted as
having unavailable locations. Aggregate-only output identifies unavailable warning details
and links inspection evidence rather than inventing locations or messages. Unknown change
scope is counted separately from unknown locations.

The complete raw logs and `gate-findings-<id>.json` retain all evidence. The same counts and
first three complete records appear in `last_gate.dialyzer_summary` in the Build JSON report.
Compact text still ends with the gate counts. Other tools' feedback keeps its existing caps.
