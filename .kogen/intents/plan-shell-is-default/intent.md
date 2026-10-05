---
title: Make plan-shell the default Build recipe
domains: [project, engine, docs]
size: medium
changes_gate: true
---
Build settings currently default to staged when project and machine configuration omit a recipe, and the benchmark runner also defaults to staged. Use plan-shell for both defaults and Kogen's own project, while preserving explicit recipe selection and every supported recipe.

## Acceptance
- A1: When project and machine settings omit a recipe, effective Build settings select plan-shell.
- A2: An explicit project recipe overrides the machine recipe, while a machine recipe applies when the project omits one.
- A3: `bin/kogen-bench` selects plan-shell when `KOGEN_BENCH_RECIPE` is unset.
- A4: `bin/kogen-bench` honors an explicit supported `KOGEN_BENCH_RECIPE` value.
- A5: Kogen's committed `.kogen/project.yaml` explicitly selects plan-shell.
- A6: Project configuration continues accepting every recipe currently supported.

## Verify
- A1: test domain=project
- A2: test keep domain=project
- A3: test domain=engine
- A4: test keep domain=engine
- A5: test domain=project
- A6: test keep domain=project

## Notes
Approach: Change `Kogen.Project.BuildSettings.effective/2` to fall back to `plan-shell`; set Kogen's `.kogen/project.yaml` recipe and `bin/kogen-bench` default to `plan-shell`. Update docs to describe the default. Preserve project-over-machine precedence, honor explicit benchmark overrides, and leave all six existing recipes available.

## Request
Benchmarks decided Kogen's default Build recipe is plan-shell (one Sol high planning call from the Intent plus the file list, then a shell-only Luna max builder, then the deterministic gate, fix loop and landing).
Make plan-shell the default recipe: when neither the project's .kogen/project.yaml nor ~/.kogen/config.yaml names a recipe, Kogen uses plan-shell, and bin/kogen-bench defaults KOGEN_BENCH_RECIPE to plan-shell. Set Kogen's own .kogen/project.yaml build recipe to plan-shell. Do not delete any recipe in this change.
