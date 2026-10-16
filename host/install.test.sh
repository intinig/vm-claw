#!/bin/bash
# Tests for host/install.sh. Scratch HOME with a fake iCloud dir; fake brew, security, launchctl,
# limactl and restic first on PATH: never the real keychain, LaunchAgents, Homebrew or iCloud.
# shellcheck disable=SC2016  # bash -c snippets are single-quoted on purpose
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
install="$here/install.sh"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; [ ! -f "$t/out" ] || cat "$t/out"; }

mkdir -p "$t/bin"
cat > "$t/bin/brew" <<'EOF2'
#!/bin/bash
echo "brew $*" >> "$FAKE_LOG"
EOF2
cat > "$t/bin/security" <<'EOF2'
#!/bin/bash
echo "security $*" >> "$FAKE_LOG"
case "$1" in
  find-generic-password)
    if [ -f "$FAKE_STATE/pw" ]; then
      case " $* " in *" -w "*) [ -z "${FAKE_VERIFY_FAIL:-}" ] || { echo "security: User interaction is not allowed." >&2; exit 36; }
        echo fake-secret-value;; esac
      exit 0
    fi
    exit 44 ;;
  add-generic-password)
    [ -z "${FAKE_KEYCHAIN_LOCKED:-}" ] || { echo "security: User interaction is not allowed." >&2; exit 36; }
    touch "$FAKE_STATE/pw" ;;
esac
EOF2
cat > "$t/bin/launchctl" <<'EOF2'
#!/bin/bash
echo "launchctl $*" >> "$FAKE_LOG"
EOF2
cat > "$t/bin/limactl" <<'EOF2'
#!/bin/bash
echo "limactl $*" >> "$FAKE_LOG"
case "$1" in
  --version) echo "limactl version 9.9.9" ;;
  list) [ -z "${FAKE_LIST_FAIL:-}" ] || { echo "limactl: fake list failure" >&2; exit 1; }
        echo "${FAKE_CLAW_STATUS:-Stopped}" ;;
esac
EOF2
cat > "$t/bin/restic" <<'EOF2'
#!/bin/bash
echo "restic $*" >> "$FAKE_LOG"
echo "restic 9.9.9 fake"
EOF2
chmod +x "$t/bin"/*

newenv() { # newenv <name>: scratch HOME with fake iCloud, empty log/state
  H="$t/$1/home"; S="$t/$1/state"; L="$t/$1/log"
  mkdir -p "$H/Library/Mobile Documents/com~apple~CloudDocs" "$H/Library/LaunchAgents" "$S"; : > "$L"
}
run() { # run [env...]: install.sh under the fake env; output in $t/out, rc in $rc
  set +e
  env -u CLAW_INSTANCE HOME="$H" USER=tester FAKE_LOG="$L" FAKE_STATE="$S" PATH="$t/bin:/usr/bin:/bin" "$@" \
    /bin/bash "$install" >"$t/out" 2>&1
  rc=$?; set -e
}
logged() { grep -Eq -- "$1" "$L"; }
plist() { echo "$H/Library/LaunchAgents/local.vm-claw.pull-backups.plist"; }

# 1. iCloud missing: exit 1 before any change (no brew, no keychain, no plist).
newenv icloud; rmdir "$H/Library/Mobile Documents/com~apple~CloudDocs"
run
if [ "$rc" -eq 1 ] && grep -q 'iCloud Drive' "$t/out" && [ ! -s "$L" ] && [ ! -e "$(plist)" ]; then ok; else bad "iCloud missing must exit 1 with no side effects (rc=$rc)"; fi

# 2. Password already present: no add.
newenv have; touch "$S/pw"
run
if [ "$rc" -eq 0 ] && ! logged 'add-generic-password'; then ok; else bad "existing password must not be re-added (rc=$rc)"; fi

# 3. Password absent: add with -s vm-claw-restic, password never in argv, then verified.
newenv add
run
if [ "$rc" -eq 0 ] && logged 'security add-generic-password -s vm-claw-restic -a tester -w$' \
   && ! grep -q 'fake-secret-value' "$L" "$t/out" \
   && [ "$(grep -c 'security find-generic-password -s vm-claw-restic -w' "$L")" -ge 1 ]; then ok
else bad "absent password: add (no argv secret) then verify (rc=$rc)"; fi

# 4. Locked keychain: remedy and non-zero; no plist written.
newenv lock
run FAKE_KEYCHAIN_LOCKED=1
if [ "$rc" -ne 0 ] && grep -q 'security unlock-keychain ~/Library/Keychains/login.keychain-db' "$t/out" \
   && grep -qi 're-run' "$t/out" && [ ! -e "$(plist)" ]; then ok; else bad "locked keychain: remedy + nonzero (rc=$rc)"; fi

# 5. Plist substituted, written to scratch LaunchAgents.
newenv sub; touch "$S/pw"
run
if [ "$rc" -eq 0 ] && [ -f "$(plist)" ] && ! grep -q '@REPO@\|@HOME@' "$(plist)" \
   && grep -q "$repo/host/pull-backups.sh" "$(plist)" && grep -q "$H/Library/Logs/vm-claw-pull-backups.log" "$(plist)"; then ok
else bad "plist must be substituted into LaunchAgents (rc=$rc)"; fi

# 6. claw Stopped: no bootstrap/bootout, note printed.
newenv stopped; touch "$S/pw"
run FAKE_CLAW_STATUS=Stopped
if [ "$rc" -eq 0 ] && ! logged 'launchctl (bootstrap|bootout)' \
   && grep -q 'pull agent installed; it is loaded when claw runs (re-run host/install.sh at cutover)' "$t/out"; then ok
else bad "claw stopped: no launchctl load, note printed (rc=$rc)"; fi

# 7. claw Running: bootout then bootstrap with the plist.
newenv running; touch "$S/pw"
run FAKE_CLAW_STATUS=Running
bo=$(grep -n 'launchctl bootout gui/[0-9]*/local.vm-claw.pull-backups' "$L" | head -1 | cut -d: -f1 || true)
bs=$(grep -n "launchctl bootstrap gui/[0-9]* $(plist)\$" "$L" | head -1 | cut -d: -f1 || true)
if [ "$rc" -eq 0 ] && [ -n "$bo" ] && [ -n "$bs" ] && [ "$bo" -lt "$bs" ]; then ok; else bad "claw running: bootout then bootstrap (rc=$rc)"; fi

# 8. lima and restic present: no brew; versions printed.
newenv present; touch "$S/pw"
run
if [ "$rc" -eq 0 ] && ! logged '^brew ' && grep -q 'limactl version 9.9.9' "$t/out" && grep -q 'restic 9.9.9' "$t/out"; then ok
else bad "tools present: no brew, versions printed (rc=$rc)"; fi

# 9. lima/restic missing: brew install each (PATH without the fake limactl/restic).
newenv missing; touch "$S/pw"; mkdir -p "$t/bin-nobrewtools"
for f in brew security launchctl; do ln -sf "$t/bin/$f" "$t/bin-nobrewtools/$f"; done
# a limactl that appears only after brew install lima (and restic likewise)
cat > "$t/bin-nobrewtools/brew" <<'EOF2'
#!/bin/bash
echo "brew $*" >> "$FAKE_LOG"
[ "$1 $2" = "install lima" ] && cp "$FAKE_REAL/limactl" "$FAKE_BIN/limactl"
[ "$1 $2" = "install restic" ] && cp "$FAKE_REAL/restic" "$FAKE_BIN/restic"
exit 0
EOF2
chmod +x "$t/bin-nobrewtools/brew"
set +e
env HOME="$H" USER=tester FAKE_LOG="$L" FAKE_STATE="$S" FAKE_REAL="$t/bin" FAKE_BIN="$t/bin-nobrewtools" \
  PATH="$t/bin-nobrewtools:/usr/bin:/bin" /bin/bash "$install" >"$t/out" 2>&1
rc=$?; set -e
if [ "$rc" -eq 0 ] && logged '^brew install lima$' && logged '^brew install restic$'; then ok; else bad "missing tools: brew install lima and restic (rc=$rc)"; fi

# 10. Idempotent: second run succeeds, same plist, no second password add, no brew.
newenv idem
run FAKE_CLAW_STATUS=Running
first=$(cat "$(plist)"); adds1=$(grep -c add-generic-password "$L" || true)
run FAKE_CLAW_STATUS=Running
adds2=$(grep -c add-generic-password "$L" || true)
if [ "$rc" -eq 0 ] && [ "$first" = "$(cat "$(plist)")" ] && [ "$adds1" -eq 1 ] && [ "$adds2" -eq 1 ] && ! logged '^brew '; then ok
else bad "re-run must be idempotent (rc=$rc adds=$adds1/$adds2)"; fi

# 11. Keep Downloaded reminder is printed.
newenv remind; touch "$S/pw"
run
if grep -q 'Keep Downloaded' "$t/out"; then ok; else bad "Keep Downloaded reminder"; fi

# 12. Item present but unreadable (locked keychain): remedy, nonzero, no secret in output, no plist.
newenv verify; touch "$S/pw"
run FAKE_VERIFY_FAIL=1
if [ "$rc" -ne 0 ] && grep -q 'security unlock-keychain ~/Library/Keychains/login.keychain-db' "$t/out" \
   && ! grep -q 'fake-secret-value' "$t/out" && [ ! -e "$(plist)" ]; then ok
else bad "present-but-unreadable password: remedy, rc!=0, no secret (rc=$rc)"; fi

# 13. HOME containing & and #: plist values intact (XML-escaped), nothing truncated, no temp files left.
newenv weird; touch "$S/pw"
W="$t/weird/a&b#c"; mkdir -p "$W/Library/Mobile Documents/com~apple~CloudDocs" "$W/Library/LaunchAgents"
H="$W"
run
if [ "$rc" -eq 0 ] && grep -qF "$t/weird/a&amp;b#c/Library/Logs/vm-claw-pull-backups.log" "$(plist)" \
   && ! grep -q '@REPO@\|@HOME@' "$(plist)" && [ "$(find "$H/Library/LaunchAgents" -type f | wc -l)" -eq 1 ]; then ok
else bad "HOME with & and # must substitute intact (rc=$rc)"; fi

# 14. limactl list itself failing: reported, still not loaded, install completes.
newenv lfail; touch "$S/pw"
run FAKE_LIST_FAIL=1
if [ "$rc" -eq 0 ] && grep -q 'fake list failure' "$t/out" && ! logged 'launchctl bootstrap'; then ok
else bad "limactl list failure must be surfaced (rc=$rc)"; fi

# 15. The pull agent pulls from the instance install.sh was given (default claw): plist environment and status check.
newenv inst; touch "$S/pw"
run
if [ "$rc" -eq 0 ] && grep -q '<key>CLAW_INSTANCE</key><string>claw</string>' "$(plist)" && ! grep -q '@INSTANCE@' "$(plist)" \
   && logged '^limactl list claw '; then ok
else bad "default instance claw in the plist and the status check (rc=$rc)"; fi

# 16. CLAW_INSTANCE=claw-next reaches the plist, the status check and the message.
newenv inst2; touch "$S/pw"
run CLAW_INSTANCE=claw-next FAKE_CLAW_STATUS=Running
if [ "$rc" -eq 0 ] && grep -q '<string>claw-next</string>' "$(plist)" && logged '^limactl list claw-next ' && grep -q 'pull agent loaded' "$t/out"; then ok
else bad "CLAW_INSTANCE=claw-next reaches the plist and the status check (rc=$rc)"; fi

# 17. A CLAW_INSTANCE that is not an instance name: refused before any change.
newenv inst3; touch "$S/pw"
run 'CLAW_INSTANCE=x;y'
if [ "$rc" -eq 2 ] && grep -q 'not an instance name' "$t/out" && [ ! -s "$L" ] && [ ! -e "$(plist)" ]; then ok
else bad "a bad CLAW_INSTANCE is refused before any change (rc=$rc)"; fi

echo "install.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
