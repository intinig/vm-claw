#!/bin/bash
# Tests for provision/vercmp.sh: dotted-version comparison, field by field, numerically.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=provision/vercmp.sh
. "$here/vercmp.sh"
pass=0; fail=0
want_cmp() { # want_cmp <a> <b> <lt|eq|gt>
  local got; got=$(vercmp "$1" "$2") || got="error"
  if [ "$got" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: vercmp $1 $2 = $got, want $3"; fi
}
want_ge() { # want_ge <a> <b> <yes|no>
  local got=no; if version_ge "$1" "$2"; then got=yes; fi
  if [ "$got" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: version_ge $1 $2 = $got, want $3"; fi
}
want_cmp 2026.9.7 2026.9.7 eq
want_cmp 2026.9.5 2026.9.7 lt
want_cmp 2026.9.8 2026.9.7 gt
want_cmp 2026.10.1 2026.9.7 gt          # a multi-digit field: numeric, not lexical
want_cmp 2026.9.7 2026.10.1 lt
want_cmp 2026.9.10 2026.9.9 gt
want_cmp 2027.1.1 2026.12.31 gt
want_cmp 2026.9 2026.9.0 eq             # a missing field is 0
want_cmp 2026.9 2026.9.1 lt
want_cmp 2026.09.7 2026.9.7 eq          # leading zeros are not octal
want_cmp 2026.9.7 2026.9.7.1 lt
want_ge 2026.9.7 2026.9.7 yes
want_ge 2026.10.1 2026.9.7 yes
want_ge 2026.9.5 2026.9.7 no
want_ge 2026.9.7 2026.10.1 no
want_ge "" 2026.9.7 no                  # unreadable is never satisfied
want_ge 2026.9.7 "" no
want_ge garbage 2026.9.7 no
want_ge 2026.9.7-beta 2026.9.7 no
want_ge 2026..9 2026.9.7 no
if vercmp garbage 2026.9.7 >/dev/null 2>&1; then fail=$((fail+1)); echo "FAIL: vercmp accepted garbage"; else pass=$((pass+1)); fi
echo "vercmp tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
