#!/bin/bash
# Tests for the openclaw line of tests/stack-check.sh, with a fake openclaw and a fixture pin. The other lines
# look at the real machine (node, op, /opt/homebrew links) and are not asserted here.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
printf 'OPENCLAW_VERSION=2026.9.7\nNODE_MAJOR=24\nWACLI_VERSION=0\nSAG_VERSION=0\n' > "$t/versions.env"
cat > "$t/bin/openclaw" <<'EOS'
#!/bin/bash
[ -z "${FAKE_RC:-}" ] || exit "$FAKE_RC"
echo "${FAKE_OUT:-OpenClaw 2026.9.7 (c074824)}"
EOS
chmod +x "$t/bin/openclaw"
pass=0; fail=0
line() { # line <openclaw --version output> [rc]: the openclaw line stack-check prints
  FAKE_OUT="$1" FAKE_RC="${2:-}" PATH="$t/bin:$PATH" VERSIONS_ENV="$t/versions.env" bash "$here/stack-check.sh" 2>&1 | grep -E '^(ok  |FAIL) openclaw' || true
}
want() { # want <description> <got> <ERE>
  if printf '%s' "$2" | grep -Eq -- "$3"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (got: $2)"; fi
}
want "the pin itself passes and shows the version"       "$(line 'OpenClaw 2026.9.7 (c074824)')"  '^ok   openclaw .*2026\.9\.7'
want "a newer patch passes and shows the installed one"  "$(line 'OpenClaw 2026.9.8 (c074824)')"  '^ok   openclaw .*2026\.9\.8'
want "a newer multi-digit field passes"                  "$(line 'OpenClaw 2026.10.1 (c074824)')" '^ok   openclaw .*2026\.10\.1'
want "an older version fails and shows it"               "$(line 'OpenClaw 2026.9.6 (c074824)')"  '^FAIL openclaw .*2026\.9\.6'
want "an older multi-digit version fails"                "$(line 'OpenClaw 2025.12.30 (c074824)')" '^FAIL openclaw'
want "an unreadable version fails"                       "$(line 'something else')"                '^FAIL openclaw'
want "a failing openclaw fails"                          "$(line 'OpenClaw 2026.9.7 (x)' 1)"       '^FAIL openclaw'
# --- the bot account, the deployed repo and the Tailscale operator (spec 2026-10-02 §1) ---
# Fakes for what those lines ask: getent, id -Gn, loginctl, tailscale, sshd, stat, passwd, and sudo, which runs the
# rest here with the bot's home mapped onto a scratch dir ($FAKE_BOT_HOME) and answers `-l -U` itself.
mkdir -p "$t/bot"
cat > "$t/bin/sudo" <<'EOS'
#!/bin/bash
if [ "$1" = -n ]; then shift; fi
if [ "$1" = -l ]; then printf '%b\n' "${FAKE_SUDO_LIST:-User sebastian is not allowed to run sudo on claw.}"; exit 1; fi
args=(); for a in "$@"; do args+=("${a//\/home\/sebastian/$FAKE_BOT_HOME}"); done
exec "${args[@]}"
EOS
cat > "$t/bin/getent" <<'EOS'
#!/bin/bash
if [ "$1 $2" = "passwd sebastian" ]; then echo "sebastian:x:${FAKE_PASSWD:-2000:2000::/home/sebastian:/bin/bash}"; else exit 2; fi
EOS
cat > "$t/bin/stat" <<'EOS'
#!/bin/bash
echo "${FAKE_STAT:-700:sebastian:sebastian}"
EOS
cat > "$t/bin/passwd" <<'EOS'
#!/bin/bash
echo "sebastian ${FAKE_PW:-L} 2026-10-02 0 99999 7 -1"
EOS
cat > "$t/bin/id" <<'EOS'
#!/bin/bash
if [ "$*" = "-Gn sebastian" ]; then echo "${FAKE_GROUPS:-sebastian}"; else exec /usr/bin/id "$@"; fi
EOS
cat > "$t/bin/loginctl" <<'EOS'
#!/bin/bash
echo "Linger=${FAKE_LINGER:-yes}"
EOS
cat > "$t/bin/sshd" <<'EOS'
#!/bin/bash
printf '%b\n' "${FAKE_SSHD:-port 22\ndenyusers sebastian\npasswordauthentication no}"
EOS
cat > "$t/bin/tailscale" <<'EOS'
#!/bin/bash
case "$*" in
  "status --json") echo "{\"BackendState\":\"${FAKE_TS_STATE:-Running}\"}" ;;
  "debug prefs") echo "{\"OperatorUser\":\"${FAKE_TS_OPERATOR-sebastian}\"}" ;;
  version) echo "1.0.0" ;;
esac
EOS
# python3 runs the real one unless FAKE_PY_RC makes it fail (a missing or broken python3).
REAL_PYTHON3=$(command -v python3); export REAL_PYTHON3
cat > "$t/bin/python3" <<'EOS'
#!/bin/bash
[ -z "${FAKE_PY_RC:-}" ] || exit "$FAKE_PY_RC"
exec "$REAL_PYTHON3" "$@"
EOS
chmod +x "$t/bin/"*
run_bot() { # run_bot [NAME=value...]: stack-check with the fakes and the given steering; output in $t/sc.out
  env "$@" FAKE_BOT_HOME="$t/bot" PATH="$t/bin:$PATH" VERSIONS_ENV="$t/versions.env" bash "$here/stack-check.sh" > "$t/sc.out" 2>&1 || true
}
has() { grep -qxF -- "$1" "$t/sc.out"; }
bot_ok() { # bot_ok <label>: that line is ok in the last run
  if has "ok   $1"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: '$1' should be ok"; grep -E '^(ok  |FAIL|skip)' "$t/sc.out" | sed 's/^/    /'; fi
}
bot_fails() { # bot_fails <label> [NAME=value...]: with that steering, that line FAILs
  local label="$1"; shift
  run_bot "$@"
  if has "FAIL $label"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: '$label' should FAIL with: $*"; grep -E '^(ok  |FAIL|skip)' "$t/sc.out" | sed 's/^/    /'; fi
}
L_USER="bot sebastian is 2000:2000, /home/sebastian, /bin/bash"
L_HOME="bot home mode 700, sebastian's"
L_PW="bot password locked"
L_GROUP="bot in its own group only"
L_SUDO="no sudo for sebastian"
L_KEYS="no SSH login keys for sebastian"
L_SSHD="sshd denies sebastian"
L_LINGER="linger sebastian"
L_TS="tailscale operator sebastian"
L_PY="python3 3.9+ with sqlite3 (the state-path migration)"
run_bot
for l in "$L_USER" "$L_HOME" "$L_PW" "$L_GROUP" "$L_SUDO" "$L_KEYS" "$L_SSHD" "$L_LINGER" "$L_TS" "$L_PY"; do bot_ok "$l"; done
want "admin's linger is no longer a stack line" "$(grep -c 'linger admin' "$t/sc.out" || true)" '^0$'
bot_fails "$L_USER" FAKE_PASSWD='2000:1000::/home/sebastian:/bin/bash'
bot_fails "$L_USER" FAKE_PASSWD='1002:1002::/home/sebastian:/bin/bash'
bot_fails "$L_USER" FAKE_PASSWD='2000:2000::/home/sebastian:/bin/sh'
bot_fails "$L_HOME" FAKE_STAT=755:sebastian:sebastian
bot_fails "$L_HOME" FAKE_STAT=700:root:root
bot_fails "$L_PW" FAKE_PW=P
bot_fails "$L_GROUP" 'FAKE_GROUPS=sebastian sudo'
bot_fails "$L_SUDO" 'FAKE_SUDO_LIST=User sebastian may run the following commands on claw:\n    (ALL) NOPASSWD: ALL'
# Review Focus 5: the check looks inside the bot's mode-700 home through sudo, so the key is found, not "absent".
mkdir -p "$t/bot/.ssh"; echo 'ssh-ed25519 AAAAx x' > "$t/bot/.ssh/authorized_keys"
bot_fails "$L_KEYS"
rm -rf "$t/bot/.ssh"
mkdir -p "$t/bot/.ssh"; echo 'ssh-ed25519 AAAAx x' > "$t/bot/.ssh/authorized_keys2"
bot_fails "$L_KEYS"
rm -rf "$t/bot/.ssh"
bot_fails "$L_SSHD" 'FAKE_SSHD=port 22'
bot_fails "$L_LINGER" FAKE_LINGER=no
bot_fails "$L_TS" FAKE_TS_OPERATOR=
bot_fails "$L_PY" FAKE_PY_RC=1
bot_fails "$L_PY" FAKE_PY_RC=127
run_bot FAKE_TS_STATE=NeedsLogin
want "a logged-out Tailscale skips the operator line and names the state" "$(grep '^skip tailscale operator' "$t/sc.out" || true)" 'Tailscale is NeedsLogin'
# The repo line, on a scratch tree: this user stands in for root (STACK_CHECK_REPO_OWNER), so a tree that is root's
# on a guest is "mine" here and the not-root-owned case is the default owner.
L_REPO="repo at /opt/vm-claw: root's, writable by no one else"
repo="$t/repo"; me=$(id -un)
fresh_repo() { rm -rf "$repo"; mkdir -p "$repo/sub"; echo abc > "$repo/DEPLOYED"; echo x > "$repo/sub/f"; chmod -R go-w "$repo"; }
repo_run() { run_bot STACK_CHECK_REPO="$repo" STACK_CHECK_REPO_OWNER="$me"; }
fresh_repo; repo_run; bot_ok "$L_REPO"
fresh_repo; run_bot STACK_CHECK_REPO="$repo" STACK_CHECK_REPO_OWNER=root
if has "FAIL $L_REPO"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a repo not owned by the expected owner should FAIL"; fi
fresh_repo; chmod g+w "$repo/sub/f"; repo_run
if has "FAIL $L_REPO"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a group-writable file should FAIL"; fi
fresh_repo; chmod o+w "$repo/sub"; repo_run
if has "FAIL $L_REPO"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a world-writable dir should FAIL"; fi
fresh_repo; rm "$repo/DEPLOYED"; repo_run
if has "FAIL $L_REPO"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a missing DEPLOYED should FAIL"; fi
if [ ! -e /opt/vm-claw ]; then
  run_bot
  want "no deployed repo: the repo line FAILs" "$(grep 'repo at /opt/vm-claw' "$t/sc.out" || true)" "^FAIL repo at /opt/vm-claw: root's"
fi
echo "stack-check tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
