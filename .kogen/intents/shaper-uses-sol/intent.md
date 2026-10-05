---
title: Use Sol high effort for shaping by default
domains: [kernel, harness, cli, docs]
size: medium
---
Shaping currently inherits the builder model and effort unless a shaper role is configured, so default planning can run on gpt-6-luna at max effort. Use gpt-6.1-sol at high effort by default, preserve explicit machine and project shaper settings and benchmark environment overrides, and document the default in `kogen help` and README.

## Acceptance
- A1: Without a shaper role, shaping selects gpt-6.1-sol at high effort even when the builder uses gpt-6-luna at max effort.
- A2: Explicit machine or project shaper settings override the default, and project fields win conflicts while inheriting unspecified machine fields.
- A3: KOGEN_BENCH_SHAPE_MODEL and KOGEN_BENCH_SHAPE_EFFORT set the selected role in a generated benchmark project.
- A4: `kogen help` states that shaping defaults to gpt-6.1-sol at high effort.
- A5: README states that shaping defaults to gpt-6.1-sol at high effort.

## Verify
- A1: test domain=kernel
- A2: test keep domain=kernel
- A3: test keep domain=harness
- A4: test domain=cli
- A5: test domain=docs

## Notes
Approach: Change `Kogen.Kernel.BuildConfig.shape_settings/1` to use gpt-6.1-sol/high when no shaper role exists instead of falling back to builder settings. Preserve machine/project role merging and precedence, leave `bin/kogen-bench`'s KOGEN_BENCH_SHAPE_* role overrides intact, and update `Kogen.Cli.Help` plus README to state the default.

## Request
Shaping and planning must use the strong model by default: when neither the project's .kogen/project.yaml nor the machine's ~/.kogen/config.yaml sets build.roles.shaper, Kogen shapes Intents with gpt-6.1-sol at high effort instead of falling back to the builder's model (today gpt-6-luna max). An explicit shaper role in either config still wins, and KOGEN_BENCH_SHAPE_MODEL / KOGEN_BENCH_SHAPE_EFFORT still override for benchmarks. `kogen help` and the README describe the default.
