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
