Test integrity inventory

Escalation reset and clean/dirty landing now execute TinyApp.value/0 in a child VM.
The opt-in live smoke gate executes Mini.greet/0, so comments or a wrong return
value cannot satisfy it. Protected-write, shell bypass, approval manifest and
restore tests retain byte comparisons: the delivered approved bytes are the contract.

Remaining coupling: direct_escalation_test and ladder_audit_test use revision
markers to identify selected attempts. Ladder progress checks use marker comments
to manufacture distinct failures. These synthetic checks can obstruct changes to
the fixture representation; production behavior is covered separately. The
review-full-diff acceptance test checks diff content because complete review
output is its public contract. shaper-uses-sol checks documented settings in README.

The gate reports likely source-spelling assertions with test locations as advisory
warnings. This AST inventory is heuristic, not proof of exhaustive independence;
aliases, indirect reads and custom helper assertions may escape detection. Review
new tests for these patterns. Inventory warnings never change the gate status.

Gate wiring is verified by feeding attempted violations through the configured
checks and checking their reports. Dependency and codec declarations can evolve
without matching a duplicate configuration map. Removing a gate or relaxing its
protection must still fail the bypass fixtures; legitimate configured interfaces
and advisory findings are checked alongside the red cases.
