SHELL := /bin/sh
.SHELLFLAGS := -eu -c
MAKEFLAGS += -j
M := mise exec --
KOGEN_PLT_DIR ?= $(HOME)/.kogen/plt
export KOGEN_PLT_DIR

TEST_ENV = GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME='Kogen Test' GIT_AUTHOR_EMAIL=test@kogen.invalid GIT_COMMITTER_NAME='Kogen Test' GIT_COMMITTER_EMAIL=test@kogen.invalid TZ=Europe/Sarajevo LC_ALL=C

.PHONY: check check-full check-fast fix guard fmt compile-dev compile-test xref credo test acceptance e2e integration kogen-checks-test dialyzer install-local demo-fixture

# macOS cannot nest Seatbelt sandboxes; inside Kogen's own sandbox the confinement test can't run.
SEATBELT_EXCLUDE := $(if $(filter 1,$(KOGEN_SANDBOXED)),--exclude seatbelt,)
KEYCHAIN_EXCLUDE := $(if $(filter 1,$(KOGEN_SANDBOXED)),--exclude keychain,)

CHECK_TASKS := guard fmt compile-dev compile-test xref credo test acceptance dialyzer
FULL_CHECK_TASKS := $(CHECK_TASKS) e2e

check:
	+$(MAKE) --no-print-directory $(CHECK_TASKS)
	@echo "check OK"

check-full:
	+$(MAKE) --no-print-directory $(FULL_CHECK_TASKS)
	@echo "check-full OK"

guard:
	$(M) mix kogen.guard

fmt:
	$(M) mix format --check-formatted

compile-dev:
	$(M) mix compile --force --warnings-as-errors

compile-test:
	$(M) mix compile --force --warnings-as-errors

compile-test test: export MIX_ENV = test
compile-test test: export GIT_CONFIG_GLOBAL = /dev/null
compile-test test: export GIT_CONFIG_NOSYSTEM = 1
compile-test test: export GIT_AUTHOR_NAME = Kogen Test
compile-test test: export GIT_AUTHOR_EMAIL = test@kogen.invalid
compile-test test: export GIT_COMMITTER_NAME = Kogen Test
compile-test test: export GIT_COMMITTER_EMAIL = test@kogen.invalid
compile-test test: export TZ = Europe/Sarajevo
compile-test test: export LC_ALL = C

xref: compile-dev
	$(M) mix xref graph --format cycles --label compile-connected --fail-above 0

credo: compile-dev
	$(M) mix credo --strict

test: compile-test kogen-checks-test
	$(TEST_ENV) MIX_ENV=test $(M) mix test --warnings-as-errors --no-compile --exclude fixture --exclude acceptance --exclude e2e $(SEATBELT_EXCLUDE) $(KEYCHAIN_EXCLUDE)

acceptance: compile-test
	$(TEST_ENV) MIX_ENV=test $(M) mix test --warnings-as-errors --no-compile --only acceptance test/acceptance

e2e: compile-test
	$(TEST_ENV) MIX_ENV=test $(M) mix test --warnings-as-errors --no-compile --only e2e test/e2e

integration: check-full
	$(TEST_ENV) MIX_ENV=test $(M) mix test --warnings-as-errors --include fixture test/fixtures_test.exs

install-local:
	$(M) mix escript.build
	@home="$(HOME)"; gen_root="$$home/.kogen/gen"; gen_sha="$$(git rev-parse HEAD)"; gen_dir="$$gen_root/$$gen_sha"; installed="$$gen_dir/kogen"; link="$$home/.local/bin/kogen"; \
	mkdir -p "$$gen_root" "$$home/.local/bin"; \
	if [ -d "$$gen_dir" ]; then \
	  if [ -f "$$installed" ] && python3 -c 'import sys,zipfile; a,b=sys.argv[1:]; same=open(a,"rb").read()[:61]==open(b,"rb").read()[:61]; left=zipfile.ZipFile(a); right=zipfile.ZipFile(b); same=same and [(i.filename,left.read(i)) for i in left.infolist()]==[(i.filename,right.read(i)) for i in right.infolist()]; sys.exit(0 if same else 1)' kogen "$$installed"; then \
	    :; \
	  else \
	    echo "refusing differing generation directory: $$gen_dir" >&2; exit 1; \
	  fi; \
	else \
	  mkdir "$$gen_dir"; cp kogen "$$installed"; chmod 755 "$$installed"; \
	fi; \
	if [ -L "$$link" ]; then rm "$$link"; elif [ -e "$$link" ]; then \
	  echo "refusing to replace non-symlink: $$link" >&2; exit 1; \
	fi; \
	ln -s "$$installed" "$$link"; echo "installed: $$installed"

demo-fixture:
	@demo_root="$(HOME)/Areas/Kogen/kogen-demo"; seed="$$demo_root/hello_app"; origin="$$demo_root/hello_app-origin-$$(date +%Y%m%d%H%M%S)-$$$$.git"; \
	if [ -e "$$seed" ] || [ -e "$$origin" ]; then \
	  echo "refusing to replace existing demo fixture path" >&2; exit 1; \
	fi; \
	mkdir -p "$$demo_root"; git init --bare --quiet "$$origin"; \
	git clone --quiet "$$origin" "$$seed"; cp -R fixtures/hello_app/. "$$seed/"; \
	git -C "$$seed" add --all; git -C "$$seed" commit --quiet -m "Seed hello_app demo"; \
	git -C "$$seed" branch -M main; git -C "$$seed" push --quiet --set-upstream origin main; \
	git -C "$$origin" symbolic-ref HEAD refs/heads/main; \
	printf 'origin=%s\nseed=%s\n' "$$origin" "$$seed"

kogen-checks-test: compile-test
	$(TEST_ENV) MIX_ENV=test $(M) mix test --warnings-as-errors --no-compile tools/kogen_checks/test

dialyzer: compile-dev
	mkdir -p "$(KOGEN_PLT_DIR)"
	$(M) mix dialyzer --quiet-with-result

check-fast:
	@if [ -z "$(D)" ]; then echo "usage: make check-fast D=<domain>" >&2; exit 2; fi
	+$(MAKE) --no-print-directory fmt compile-dev compile-test
	$(M) mix credo --strict lib/kogen/$(D).ex
	$(M) mix credo --strict lib/kogen/$(D)
	@test_files=$$(find "test/$(D)" -type f -name '*_test.exs' -print -quit 2>/dev/null); if [ -n "$$test_files" ]; then $(M) mix credo --strict test/$(D); else echo "No tests for $(D) yet"; fi
	@test_files=$$(find "test/$(D)" -type f -name '*_test.exs' -print -quit 2>/dev/null); if [ -n "$$test_files" ]; then $(TEST_ENV) MIX_ENV=test $(M) mix test --warnings-as-errors --no-compile test/$(D); else echo "No tests for $(D) yet"; fi

fix:
	$(M) mix format --force
