Advisory mutation qualification

Both Elixir gates qualify binary comparison, arithmetic and boolean operators on
changed production lines. New untracked lib files are included. Trials run the
project's test files with seed 0 in a separate snapshot, never the Candidate.
The unmutated suite must pass first. Six trials, five seconds per process and the
shared 24-second quality budget bound the work. Reports include eligible/tried
counts, scope, completeness, locations, selected tests, logs, commands and time.
Invalid, unavailable and timed-out trials make qualification incomplete. Other
mutation operators and behavior outside changed lines are not qualified.

Survivors are advice, never a blocking score. The same builder receives surviving
locations and tests in a bounded no-tool follow-up; a failed follow-up cannot
prevent Build completion. Mutation-ignore comments have no effect. To claim an
equivalent mutant, record its location, original and replacement operator, and a
concrete explanation with input/output evidence in the Build report; survivors
remain listed. The tool never infers equivalence or silently suppresses a trial.

Calibration is pending. Collect mutation-qualification.json from real Builds,
record survivors repaired versus demonstrated equivalent, delivered acceptance
results, valid refactors rejected, and qualification costs/completeness. Compare
delivery success and false rejections before proposing any blocking policy.
Synthetic regression fixtures demonstrate detection, not real-Build calibration.
