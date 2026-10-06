Projects can declare exact setup input files in `.kogen/project.yaml`:

```yaml
setup_inputs: [mix.lock, mix.exs, mise.toml]
setup_outputs: [deps, _build]
```

Include every file the setup commands depend on, including toolchain declarations
and scripts they run. The cache key covers their content and file mode, setup
commands, declared outputs, project environment, resolved process environment,
OS, architecture, Elixir and OTP versions. Unrelated source edits can reuse the
prepared outputs. Without `setup_inputs`, the whole base tree remains the input
for compatibility. Empty lists, globs and unsafe paths are rejected.

Missing, unreadable, directory or symlink inputs produce an uncached setup run.
The ordinary setup command still runs and its errors are preserved. Setup that
changes its own inputs does not publish under the old key. Cached outputs are
copied into each Candidate, so later writes do not mutate the stored setup.
This cache is separate from the dependency seed store.

Build status shows preparation time or reuse with saved preparation time. The
JSON report exposes `setup_prepared` and `setup_reused` observations in `setup`;
shaping journals retain the same events.
