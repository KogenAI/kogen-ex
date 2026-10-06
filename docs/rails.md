# Rails projects

Kogen detects Rails from **both** `Gemfile` and `config/application.rb`. Projects still declare
their domains in `.kogen/project.yaml`, for example:

```yaml
name: bookstore
domains:
  books: [app/models, app/controllers, test]
```

Rails supplies defaults for omitted verification settings. Explicit project settings take
precedence, including `checks`, `setup`, `acceptance_checks`, `format` and `fix`.

| Integration point | Elixir | Rails |
| --- | --- | --- |
| Checks | Existing project configuration; benchmark Mix tests and format | `bundle exec rails test`, plus declared Standard/RuboCop checks |
| Acceptance source | `.kogen/acceptance/<slug>_test.exs` | `.kogen/acceptance/<slug>_test.rb` |
| Staged acceptance | `test/acceptance/<slug>_test.exs` | `test/acceptance/<slug>_test.rb` |
| Acceptance runner | ExUnit controller formatter | `bundle exec rails test {path}` with a controller Minitest reporter |
| Acceptance validation | Existing configured commands | `ruby -c {path}` |
| Formatting | Existing format argv or Mix format | `bundle exec standardrb -a`, otherwise `bundle exec rubocop -a`, when declared |
| Workspace dependencies | Clone `deps/` and `_build/` | Seed `vendor/cache/`; run `bundle install --local` |
| Sandbox caches | Existing mise/Hex/rebar/npm cache paths | Bundle and Rails caches inside the workspace |

Standard and RuboCop are detected from their Gemfile/lockfile declarations or their project
configuration files. Host-installed linters do not enable a check. A Rails project without a
declared formatter skips controller formatting and still runs its checks.

The Rails shaper writes Minitest tests using the project's `test_helper`. Name each test for
its acceptance item: Rails `test "A1 requested outcome" do ... end`, or plain Minitest
`def test_A1_requested_outcome`. Names identify the item in Kogen's ledger. Missing items,
skips, unknown item ids, loading failures and nonzero suite exits remain failures. `test`
items must fail on the unchanged base; `test keep` items must pass there. Approval, protected
test restoration, build, gate and landing use the Ruby paths throughout. Cross-checks and
optional edge probes also run Rails tests.

Bundle installation is offline: cache the required gems in `vendor/cache` or make their
installed gem archives available through the task's `GEM_HOME`/`GEM_PATH`. Kogen forwards
Ruby/Bundler toolchain variables. The default `BUNDLE_PATH` is `.bundle/gems`; an explicit
value is honored. With `GEM_HOME` alone, Kogen uses the installed gems there; with
`BUNDLE_APP_CONFIG`, Bundler selects the configured cache path. Kogen preserves these variables
and `BUNDLE_USER_HOME`, defaulting metadata directories under `.bundle` only when absent.
All bundle commands use frozen/deployment settings. Setup first checks the installed bundle
without changing its lockfile, then installs with `--local` and file-only Git transport if
needed; a missing gem fails setup with Bundler's gem name instead of downloading it.
macOS Seatbelt already
permits reading and executing Ruby, Bundler, SQLite and their libraries; writes stay in the
workspace/run/temp paths, and the existing origin and
credential protections apply. Linux retains the existing unrestricted process policy.

[Bundler's local installation documentation](https://bundler.io/man/bundle-install.1.html)
describes its cache requirements; Kogen does not download missing gems as a fallback.

`bin/kogen-bench` recognizes the same Rails markers. When public task setup applies
`environment.patch`, it applies that patch to the throwaway benchmark project **before**
freezing its base. It preserves remaining setup commands and task environment, installs the
bundle locally in each workspace, and does not require `KOGEN_BENCH_DEPS_SOURCE` or advertise
`deps/_build` setup outputs for Rails. An inapplicable patch fails explicitly. Provided Rails
Intents use `acceptance_test.rb`. On a shaping provider outage, the configured raw fallback
uses the documented project-check-only Intent mode, without inventing a smoke acceptance test.

The offline fixture in `fixtures/rails_app` is a real Rails application with a greeting route,
an integration test and locked gem archives. Tests use an installed Ruby 3.4.8, its bundled
Bundler 2.6.9, and the vendored
arm64-darwin Nokogiri archive; they print an explicit skip reason when that runtime/platform is
unavailable. The scripted shape/build test proves a changed response red on the base, an HTTP
status preserved on the base, green gate receipts and a landed commit. Additional tests cover
missing/skipped/unknown acceptance items, paths with spaces, patch-based benchmark setup and
new Rails failures on an already-red base.
