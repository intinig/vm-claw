SHELL := /bin/bash
# find, not git ls-files: new files must be linted and tested before their first commit.
SH_FILES = $(shell find . -name '*.sh' -not -path './.git/*')
TEST_FILES = $(shell find migrate ops -name '*.test.mjs' 2>/dev/null)

.PHONY: lint unit unit-bash32 test
lint:
	@if [ -n "$(SH_FILES)" ]; then shellcheck -x $(SH_FILES); else echo "lint: no shell files yet"; fi

unit:
	@if [ -n "$(TEST_FILES)" ]; then node --test $(TEST_FILES); else echo "unit: no tests yet"; fi
	@bash migrate/import.test.sh
	@bash migrate/home-roots.test.sh
	@python3 migrate/state-paths.test.py
	@bash migrate/rehome.test.sh
	@bash ops/backup/backup.test.sh
	@bash host/install.test.sh
	@bash host/claw.test.sh
	@bash tests/acceptance.test.sh
	@bash tests/stack-check.test.sh
	@bash tests/lib.test.sh
	@bash provision/vercmp.test.sh

# The host-side scripts run on macOS, whose /bin/bash is 3.2: run their suites under it, with /bin first so the
# scripts under test (which start `bash`) get 3.2 too.
unit-bash32:
	@PATH=/bin:$$PATH /bin/bash host/claw.test.sh
	@PATH=/bin:$$PATH /bin/bash host/install.test.sh
	@PATH=/bin:$$PATH /bin/bash ops/backup/backup.test.sh

test: lint unit unit-bash32
