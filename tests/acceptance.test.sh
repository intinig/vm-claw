#!/bin/bash
# Tests for tests/acceptance.sh: the real script, run from a scratch copy of the repo layout, against fake
# openclaw, op, wacli, git, node and timeout on PATH (and a fake firewall-check.sh beside it), with a scratch
# HOME and TMPDIR. No gateway, 1Password, WhatsApp, network or model call is ever involved.
# The fakes answer with the output shapes recorded in docs/verification.md and are steered per call by
# FAKE_RC_<key> (exit status), FAKE_OUT_<key> (stdout, even empty) and FAKE_ERR_<key> (stderr).
# The script runs under the same bash as this file, so `/bin/bash tests/acceptance.test.sh` covers bash 3.2.
# The bash -c snippets below are single-quoted on purpose: they expand inside the child shell.
# shellcheck disable=SC2016
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
t=$(mktemp -d); acclog=""
trap 'rm -rf "$t"; [ -z "${acclog:-}" ] || rm -f "$acclog"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
pass=0; fail=0
check() { # check <description> <cmd...>: the command must succeed
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL: $desc"
    sed 's/^/    out: /' "$t/out" 2>/dev/null | tail -14 || true
    sed 's/^/    err: /' "$t/err" 2>/dev/null | tail -4 || true
  fi
}

# Obviously fake, and inside what a dotenv file can carry unquoted. They are planted where leaks would show.
SA_TOKEN=fixture-sa-token-0001; GW_TOKEN=fixture-gw-token-0002
LAN=192.0.2.10   # a documentation address (RFC 5737); the script takes the address as an argument and has no default
export SA_TOKEN GW_TOKEN
# A fixed fixture pin (the fixture's versions.env is written from it): the older/newer/multi-digit cases below are
# relative to it and must not move when the real pin in provision/versions.env is bumped.
pin=2026.9.7
put_pin() { printf 'OPENCLAW_VERSION=%s\nNODE_MAJOR=24\n' "$pin" > "$t/repo/provision/versions.env"; }

# ===== fakes =======================================================================================
export FAKE_BIN="$t/bin" FAKE_LOG="$t/calls"
mkdir -p "$t/bin" "$t/repo/tests" "$t/repo/ops/lib" "$t/repo/provision" "$t/nojq"
cat > "$t/bin/.fake.sh" <<'EOF'
# Sourced by every fake.
# reply <key> <default stdout>: prints FAKE_OUT_<key> when that is set (even empty), else the default; prints
# FAKE_ERR_<key> on stderr; exits with FAKE_RC_<key> (default 0).
reply() {
  local out_var="FAKE_OUT_$1" err_var="FAKE_ERR_$1" rc_var="FAKE_RC_$1"
  if [ -n "${!out_var+x}" ]; then printf '%s\n' "${!out_var}"; else printf '%s\n' "$2"; fi
  if [ -n "${!err_var+x}" ]; then printf '%s\n' "${!err_var}" >&2; fi
  exit "${!rc_var:-0}"
}
# hold <key>: when FAKE_HOLD_<key> names a file, create it (the test's cue that this call is under way) and stay
# here a little, so a test can send the script a signal while this command is the one in flight.
hold() {
  local v="FAKE_HOLD_$1"
  if [ -n "${!v:-}" ]; then : > "${!v}"; sleep 2; fi
}
# logcall <argv text>: one line per call, with whether each token is in this process's environment (a
# comparison: a token's value never reaches the log, so a token in the log can only have come from argv)
# and how many bytes of stdin it could read (the script must have closed it).
logcall() {
  echo "$1 | sa=$([ "${OP_SERVICE_ACCOUNT_TOKEN:-}" = "$SA_TOKEN" ] && echo ok || echo no) gw=$([ "${OPENCLAW_GATEWAY_TOKEN:-}" = "$GW_TOKEN" ] && echo ok || echo no) stdin=$(head -c 64 | wc -c | tr -d ' ')" >> "$FAKE_LOG"
}
EOF
cat > "$t/bin/openclaw" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "openclaw $*"
case "$1" in
  --version) reply version "OpenClaw $FAKE_PIN (c074824)" ;;
  agent)     key=primary; for a in "$@"; do [ "$a" = --model ] && key=fallback; done
             hold "$key"
             reply "$key" '{"runId":"r1","status":"ok","summary":"completed","result":{"payloads":[{"text":"pong"}],"meta":{"durationMs":900}}}' ;;
esac
case "$1 $2" in
  "secrets audit")   hold audit; reply audit "Secrets audit: clean. plaintext=0, unresolved=0, shadowed=0, storeResidue=0, legacy=0." ;;
  "update status")   reply update '{"update":{"installKind":"package","packageManager":"npm"},"channel":{"value":"stable"},"availability":{"available":false},"recoverySets":[]}' ;;
  "sessions delete") reply delete "deleted agent:main:bench:acc-primary, agent:main:bench:acc-fallback" ;;
  "channels status") reply channels 'Checking channel status…
Gateway reachable.

- WhatsApp default: enabled, configured, linked, running, connected, dm:allowlist' ;;
  "memory status")   reply memory "Memory (main)
  workspaceDir: $HOME/.openclaw/workspace
  dbPath: $HOME/.openclaw/memory/main.sqlite
  files: 42, chunks: 310" ;;
esac
exit 0
EOF
cat > "$t/bin/op" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "op $*"
if [ -n "${FAKE_OP_FAIL:-}" ]; then echo "[ERROR] service account token rejected: ${OP_SERVICE_ACCOUNT_TOKEN:-}" >&2; exit 1; fi
reply op "$GW_TOKEN"
EOF
cat > "$t/bin/wacli" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "wacli $*"
reply wacli '{"success":true,"data":{"authenticated":true},"error":null}'
EOF
cat > "$t/bin/git" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "git $*"
reply vault "0123456789abcdef0123456789abcdef01234567	HEAD"
EOF
cat > "$t/bin/node" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "node $* | logdir=${GUARD_LOG_DIR:-} state=${GUARD_STATE:+set}"
case " $* " in
  *" --dry-run --now "*)
    hold replay
    # A rehearsal drill has no WhatsApp link, so the guard reaches "not linked"; a final guest is linked and restarts.
    # FAKE_REPLAY_RESTARTS plays a guard that runs its restart command even on a dry run.
    if [ -n "${FAKE_REPLAY_RESTARTS:-}" ]; then sh -c "$GUARD_RESTART"; fi
    if [ "${FAKE_MODE:-}" = final ]; then reply replay "[dry-run] 2026-09-30T09:02:00.000Z restart: stranded listener (2 events)"
    else reply replay "[dry-run] 2026-09-30T09:02:00.000Z skip: WhatsApp not linked (2 events)"; fi ;;
  *" --now "*)
    # The installed guard asked to act on replayed history: it must refuse. FAKE_REFUSE_RESTARTS plays an old guard
    # that runs its restart command instead.
    if [ -n "${FAKE_REFUSE_RESTARTS:-}" ]; then sh -c "$GUARD_RESTART"; echo "2026-09-30T09:02:00.000Z restart: stranded listener (2 events)"; exit 0; fi
    v=FAKE_RC_refuse; export FAKE_RC_refuse="${!v:-2}"
    export FAKE_ERR_refuse="${FAKE_ERR_refuse-guard: --now replays recorded history; it only runs with --dry-run (refusing to restart the gateway)}"
    reply refuse "" ;;
  *) reply guard "ok: 0 event(s) in window" ;;
esac
EOF
cat > "$t/bin/timeout" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "timeout $1"
shift
exec "$@"
EOF
cat > "$t/bin/sudo" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "sudo $*"
case "$*" in "-n true") key=sudotrue ;; "-n -l") key=sudolist ;; *) key=sudoother ;; esac
v="FAKE_RC_$key"; export "FAKE_RC_$key=${!v:-1}"
reply "$key" ""
EOF
cat > "$t/bin/nft" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "nft $*"
export FAKE_RC_nft="${FAKE_RC_nft:-1}"
export FAKE_ERR_nft="${FAKE_ERR_nft-Error: Operation not permitted}"
reply nft ""
EOF
cat > "$t/bin/systemctl" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "systemctl $*"
case "$*" in
  "--user show openclaw-gateway.service -p MainPID --value") reply mainpid 4242 ;;
  "--user show openclaw-listener-guard.service -p Environment --value") reply environment "GUARD_LOG_DIR=$FAKE_GWLOG" ;;
  "--user is-enabled openclaw-nightly-backup.timer") reply enabled_nightly enabled ;;
  "--user is-enabled "*) reply "enabled" "enabled" ;;
esac
reply systemctl ""
EOF
cat > "$t/bin/ps" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "ps $*"
case "$*" in
  "-o uid= -p "*) reply psowner "  $(id -u)" ;;
  "-eo pid=,uid=,args= ww") reply pstable "$(cat "$FAKE_PSTABLE")" ;;
esac
reply ps ""
EOF
# The script is staged as tests/acceptance.sh beside this fake, so it finds it the way it finds the real one.
cat > "$t/repo/tests/firewall-check.sh" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "firewall-check $*"
hold firewall
reply firewall "firewall: OK"
EOF
chmod +x "$t/bin/"* "$t/repo/tests/firewall-check.sh"
cp "$here/acceptance.sh" "$t/repo/tests/acceptance.sh"
cp "$repo/ops/lib/dotenv-token.sh" "$t/repo/ops/lib/"
put_pin
cp "$repo/provision/vercmp.sh" "$t/repo/provision/"
mkdir -p "$t/repo/ops/listener-guard/fixtures/stranded-listener"
cp "$repo/ops/listener-guard/fixtures/stranded-listener/"*.log "$t/repo/ops/listener-guard/fixtures/stranded-listener/"
# The process table ps shows: the bot's gateway and guard under this uid, system processes, and another account's
# near misses (an old log of the gateway's is not the gateway). $other is never this uid.
other=4999; if [ "$(id -u)" = 4999 ]; then other=4998; fi
printf '    1     0 /sbin/init\n 4242 %s /usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js gateway --port 18789\n 4300 %s /usr/bin/node %s/ops/listener-guard/guard.mjs\n  900     0 /usr/sbin/sshd -D\n 5000 %s -bash\n 5001 %s less /tmp/openclaw.pre-rehome-20261002T120000Z/openclaw-2026-10-02.log\n' \
  "$(id -u)" "$(id -u)" "$t/home" "$other" "$other" > "$t/pstable"
export FAKE_PSTABLE="$t/pstable" FAKE_GWLOG="$t/gwlog"
# A toolbox without nft (and without the system dirs), for the missing-nft test.
mkdir -p "$t/nonft"
for f in "$t/bin/"*; do if [ "$(basename "$f")" != nft ]; then ln -s "$f" "$t/nonft/$(basename "$f")"; fi; done
for c in bash dirname sed grep cat mktemp rm tail cut head tr sort awk env jq id wc basename; do p=$(command -v "$c") && ln -sf "$p" "$t/nonft/$c"; done
export FAKE_PIN="$pin"
# A toolbox without jq, for the missing-dependency test: every external the script needs except jq.
for c in dirname sed grep cat mktemp rm tail cut head tr sort awk env; do ln -s "$(command -v "$c")" "$t/nojq/$c"; done

echo "input waiting on the caller's stdin" > "$t/stdin"
fresh() { # a healthy guest: fixtures recreated, every FAKE_* steering variable cleared
  local v
  for v in $(compgen -v FAKE_RC_) $(compgen -v FAKE_OUT_) $(compgen -v FAKE_ERR_) $(compgen -v FAKE_OP_) $(compgen -v FAKE_HOLD_); do unset "$v"; done
  rm -rf "${t:?}/home" "${t:?}/tmp" "${t:?}/gwlog"
  mkdir -p "$t/home/.openclaw" "$t/home/ops/listener-guard" "$t/home/brain/vault" "$t/home/brain/queue" "$t/tmp" "$t/gwlog"
  printf 'OP_SERVICE_ACCOUNT_TOKEN=%s\n' "$SA_TOKEN" > "$t/home/.openclaw/.env"
  echo '// stands in for the guard' > "$t/home/ops/listener-guard/guard.mjs"
  printf '{"ok":true,"at":"2026-01-01T00:00:00Z"}\n' > "$t/home/brain/queue/harvest-health.json"
  echo '{"1":"gateway ready"}' > "$t/gwlog/openclaw-2026-10-02.log"
  unset FAKE_REFUSE_RESTARTS FAKE_REPLAY_RESTARTS || true
  unset ACC_PATH ACC_EXTRA || true
}
rc=0
acc() { # acc <args...>: run the staged script; stdout in $t/out, stderr in $t/err, exit status in $rc, calls in $FAKE_LOG
  : > "$FAKE_LOG"
  set +e
  env HOME="$t/home" TMPDIR="$t/tmp" PATH="${ACC_PATH:-$t/bin:$PATH}" FAKE_MODE="${1:-}" ${ACC_EXTRA:+"$ACC_EXTRA"} "$BASH" "$t/repo/tests/acceptance.sh" "$@" >"$t/out" 2>"$t/err" <"$t/stdin"
  rc=$?
  set -e
}
acc_signal() { # acc_signal <SIGNAL> <hold key> <args...>: run the script in the background, send it SIGNAL while the fake
  # for <hold key> is the command in flight, and wait for it to end. Job control (set -m) gives the job the default
  # signal handling: a plain background job of a non-interactive shell ignores SIGINT.
  local sig=$1 key=$2 pid n=0; shift 2
  : > "$FAKE_LOG"; rm -f "$t/held"
  export "FAKE_HOLD_$key=$t/held"
  set +e; set -m
  env HOME="$t/home" TMPDIR="$t/tmp" PATH="${ACC_PATH:-$t/bin:$PATH}" FAKE_MODE="${1:-}" "$BASH" "$t/repo/tests/acceptance.sh" "$@" >"$t/out" 2>"$t/err" <"$t/stdin" &
  pid=$!
  set +m
  while [ ! -e "$t/held" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  kill "-$sig" "$pid"
  wait "$pid"; rc=$?
  set -e
  [ -e "$t/held" ]   # the fake was reached: the signal really came mid-command
}
out_has() { grep -qxF -- "$1" "$t/out"; }          # a whole stdout line
out_re() { grep -Eq -- "$1" "$t/out"; }
err_re() { grep -Eq -- "$1" "$t/err"; }
log_re() { grep -Eq -- "$1" "$FAKE_LOG"; }
log_order() { # log_order <ere>...: the first call matching each pattern comes after the first matching the one before
  local prev=0 n pat
  for pat in "$@"; do
    n=$(grep -nE -- "$pat" "$FAKE_LOG" | head -1 | cut -d: -f1)
    if [ -z "$n" ] || [ "$n" -le "$prev" ]; then return 1; fi
    prev=$n
  done
}
no_items() { ! out_re '^(PASS|FAIL|MANUAL) ' && ! log_re '^openclaw '; }   # the script stopped before its first item
tmp_clean() { [ -z "$(ls -A "$t/tmp")" ]; }

I_ROOT="privilege: the bot account cannot become root or touch the firewall"
I_OWNER="privilege: every bot process runs as the bot account"
I_AUDIT="secrets audit: 0 unresolved"
I_UPDATE="update status: no failed run, installed version is at least the pin"
I_PRIMARY="agent probe: primary"
I_FALLBACK="agent probe: fallback"
I_FW="firewall"
I_GUARD="listener guard dry run"
I_REPLAY="listener guard replays a stranded-listener log and would restart"
I_REFUSE="listener guard refuses --now without --dry-run"
I_GWLOG="gateway log dir belongs to the bot account (the guard reads it)"
I_MEMORY="memory index paths are under this home"
I_VAULT="vault remote reachable with deploy key"
I_WA="WhatsApp linked + connected"
I_WACLI="wacli authenticated"
I_HARVEST="harvest health ok"
rehearsal_items=$(printf '%s\n' "$I_ROOT" "$I_OWNER" "$I_AUDIT" "$I_UPDATE" "$I_PRIMARY" "$I_FALLBACK" "$I_FW" "$I_GUARD" "$I_REPLAY" "$I_REFUSE" "$I_GWLOG" "$I_MEMORY" "$I_VAULT")
final_items=$(printf '%s\n' "$rehearsal_items" "$I_WA" "$I_WACLI" "$I_HARVEST")
n_reh=$(printf '%s\n' "$rehearsal_items" | wc -l | tr -d ' ')
n_fin=$(printf '%s\n' "$final_items" | wc -l | tr -d ' ')
MANUAL_REH=$(printf '%s\n' \
  "doctor shows no new warnings versus the pre-migration baseline (compare on a drill, with the gateway stopped: doctor writes)" \
  "memory search returns results: openclaw memory search <a word from a recent note> --agent main")
MANUAL_FIN=$(printf '%s\n' "$MANUAL_REH" \
  "one real WhatsApp message gets a reply" \
  "first scheduled ocsb-ingest and one announce job succeed (openclaw automations list --json)" \
  "face in gateway presence (host: the panel shows the face)" \
  "voice round-trip: a voice-gateway chat.send gets a spoken reply" \
  "ssh admin@<name> over Tailscale, and limactl shell claw from the host" \
  "a vault commit pushed since cutover (git -C ~/brain/vault log -1 origin/HEAD)" \
  'restore drill (README "Restore")')
passed_lines() { sed -n 's/^PASS   //p' "$t/out"; }

only_fails() { # only_fails <item> <PASS count expected>: exit 1, that item is the one FAIL, every other item ran and passed
  [ "$rc" -eq 1 ] \
    && [ "$(grep -c '^FAIL ' "$t/out")" -eq 1 ] && out_has "FAIL   $1" \
    && [ "$(grep -c '^PASS ' "$t/out")" -eq "$2" ] \
    && ! out_re 'automated items PASS$'
}
both_ways() { # both_ways <mode> <item> <key> <stdout that must not match>
  local mode=$1 name=$2 key=$3 bad=$4 want
  if [ "$mode" = final ]; then want=$((n_fin - 1)); else want=$((n_reh - 1)); fi
  fresh; export "FAKE_RC_$key=1"; acc "$mode" "$LAN"
  check "$name: the producer ($key) exits non-zero while its output still matches -> FAIL, the rest PASS" only_fails "$name" "$want"
  fresh; export "FAKE_OUT_$key=$bad"; acc "$mode" "$LAN"
  check "$name: the producer ($key) exits 0 but its output does not match -> FAIL, the rest PASS" only_fails "$name" "$want"
}
passes() { out_has "PASS   $1" && [ "$rc" -eq 0 ]; }
item_with() { # item_with <mode> <item> <key> <stdout> <PASS|FAIL>: one steered answer, and what that one item then reports
  local mode=$1 name=$2 key=$3 out=$4 want=$5 total
  if [ "$mode" = final ]; then total=$n_fin; else total=$n_reh; fi
  fresh; export "FAKE_OUT_$key=$out"; acc "$mode" "$LAN"
  local shown; shown=$(printf '%s' "$out" | head -c 70 | tr '\n\033' '  ')
  if [ "$want" = PASS ]; then check "$name: $key answers [$shown] -> PASS" passes "$name"
  else check "$name: $key answers [$shown] -> FAIL, the rest PASS" only_fails "$name" $((total - 1)); fi
}

# ===== Part 1: the healthy paths ====================================================================
fresh; acc rehearsal "$LAN"
check "rehearsal, everything healthy: exit 0" test "$rc" -eq 0
check "rehearsal prints PASS for exactly the rehearsal items, in checklist order" test "$(passed_lines)" = "$rehearsal_items"
check "rehearsal ends with the summary line" out_has "acceptance (rehearsal): automated items PASS"
check "rehearsal prints no FAIL" bash -c '! grep -Eq "^FAIL " "$1"' _ "$t/out"
check "rehearsal prints exactly the two MANUAL lines a drill can answer, verbatim and in order" test "$(sed -n 's/^MANUAL //p' "$t/out")" = "$MANUAL_REH"
check "rehearsal prints no final-only item" bash -c '! grep -Eq "WhatsApp|wacli|harvest" "$1"' _ "$t/out"
check "rehearsal never asks about channels or wacli" bash -c '! grep -Eq "^(wacli|openclaw channels)" "$1"' _ "$FAKE_LOG"
check "secrets are audited with --allow-exec" log_re '^openclaw secrets audit --allow-exec \|'
check "the update status is read as JSON" log_re '^openclaw update status --json \|'
check "the primary probe is the plan's, verbatim" log_re '^openclaw agent --agent main --session-key bench:acc-primary -m Reply with exactly: pong --json \|'
check "the fallback probe names luna, otherwise verbatim" \
  log_re '^openclaw agent --agent main --session-key bench:acc-fallback --model openai/gpt-6-luna -m Reply with exactly: pong --json \|'
check "the firewall check gets the LAN address as its argument" log_re "^firewall-check $LAN \\|"
check "the guard runs from the installed copy, as a dry run" log_re "^node $t/home/ops/listener-guard/guard.mjs --dry-run \\|"
check "the vault is asked over git, bounded by a timeout" log_order '^timeout 60 \|' "^git -C $t/home/brain/vault ls-remote origin HEAD \\|"
check "the gateway token is read from the plan's 1Password item" log_re '^op read op://Sebastian/OpenClaw Gateway Token/password \|'
check "a healthy run leaves nothing in TMPDIR" tmp_clean

fresh; acc final "$LAN"
check "final, everything healthy: exit 0" test "$rc" -eq 0
check "final prints PASS for the rehearsal items plus the three final-only ones, in order" test "$(passed_lines)" = "$final_items"
check "final ends with the summary line" out_has "acceptance (final): automated items PASS"
check "final prints exactly the nine MANUAL lines, verbatim and in order" test "$(sed -n 's/^MANUAL //p' "$t/out")" = "$MANUAL_FIN"
check "final asks the gateway for channel status and wacli for a read-only auth status" \
  bash -c 'grep -q "^openclaw channels status |" "$1" && grep -q "^wacli auth status --read-only --json |" "$1"' _ "$FAKE_LOG"
check "final: the probe sessions are deleted at the normal point, before the final-only items (not left to the exit)" \
  log_order '--session-key bench:acc-fallback' '^openclaw sessions delete ' '^openclaw channels status'
check "a healthy final run leaves nothing in TMPDIR" tmp_clean

check "no command is left able to read the caller's stdin (op and every item's command get it closed)" \
  bash -c 'grep -q "stdin=0" "$1" && ! grep -q "stdin=[1-9]" "$1"' _ "$FAKE_LOG"

# ===== Part 2: every item fails both ways, and only that item ========================================
# "Both ways": the producing command exits non-zero (output still the matching kind), or exits 0 with output
# that does not match. Each case must fail that item alone: every other item still runs and passes.
both_ways rehearsal "$I_AUDIT" audit "Secrets audit: findings. plaintext=0, unresolved=2, shadowed=0, storeResidue=0, legacy=0."
both_ways rehearsal "$I_UPDATE" update "this is not JSON"
both_ways rehearsal "$I_UPDATE" version "OpenClaw 2026.9.6 (c074824)"
both_ways rehearsal "$I_PRIMARY" primary '{"status":"ok","result":{"payloads":[{"text":"I cannot help"}],"meta":{"prompt":"Reply with exactly: pong"}}}'
both_ways rehearsal "$I_FALLBACK" fallback '{"status":"ok","result":{"payloads":[{"text":"I cannot help"}],"meta":{"prompt":"Reply with exactly: pong"}}}'
both_ways rehearsal "$I_FW" firewall "firewall: skipped"
both_ways rehearsal "$I_GUARD" guard "Error: ENOENT: no such file or directory, scandir '/tmp/openclaw'"
both_ways rehearsal "$I_VAULT" vault ""
both_ways final "$I_WA" channels 'Gateway auth unavailable; showing config-only status.

- WhatsApp default: enabled, configured, linked'
both_ways final "$I_WACLI" wacli '{"success":true,"data":{"authenticated":false},"error":null}'

# stdout and stderr are kept apart: a warning on stderr must not spoil a JSON reply.
fresh; export FAKE_ERR_primary="[plugins] warning: something unrelated on stderr" FAKE_ERR_update="warning: update check slow" FAKE_ERR_wacli="store opened"; acc final "$LAN"
check "warnings on stderr do not turn JSON-reading items into FAILs" test "$rc" -eq 0

# harvest-health.json is a file read: a missing file is the producer failing, other content the output not matching.
fresh; rm "$t/home/brain/queue/harvest-health.json"; acc final "$LAN"
check "$I_HARVEST: a missing harvest-health.json -> FAIL, the rest PASS" only_fails "$I_HARVEST" $((n_fin - 1))
fresh; printf '{"ok":false}\n' > "$t/home/brain/queue/harvest-health.json"; acc final "$LAN"
check "$I_HARVEST: a file that says ok:false -> FAIL, the rest PASS" only_fails "$I_HARVEST" $((n_fin - 1))
fresh; printf '{\n  "ok": true\n}\n' > "$t/home/brain/queue/harvest-health.json"; acc final "$LAN"
check "$I_HARVEST: a pretty-printed ok: true passes" out_has "PASS   $I_HARVEST"

# One item failing does not stop the others, and the exit status and summary say so.
fresh; export FAKE_RC_firewall=1 FAKE_OUT_firewall="FAIL: LAN address $LAN reachable on 80"; acc final "$LAN"
check "one FAIL: exit status 1" test "$rc" -eq 1
check "one FAIL: the item is marked FAIL, with the tail of what it printed" bash -c 'grep -qx "FAIL   firewall" "$1" && grep -q "^       FAIL: LAN address 192.0.2.10 reachable on 80$" "$1"' _ "$t/out"
check "one FAIL: items after it still ran (vault, then the final-only ones)" \
  bash -c 'grep -qx "PASS   vault remote reachable with deploy key" "$1" && grep -qx "PASS   harvest health ok" "$1"' _ "$t/out"
check "one FAIL: the MANUAL lines still print" bash -c '[ "$(grep -c "^MANUAL " "$1")" -eq 9 ]' _ "$t/out"
check "one FAIL: the summary says FAILED and no line claims PASS for the run" \
  bash -c 'grep -qx "acceptance (final): 1 automated item(s) FAILED" "$1" && ! grep -q "automated items PASS" "$1"' _ "$t/out"
check "a failing run leaves nothing in TMPDIR" tmp_clean
fresh; export FAKE_RC_firewall=1 FAKE_RC_guard=1 FAKE_RC_vault=1; acc rehearsal "$LAN"
check "three FAILs are all reported, in the summary too" \
  bash -c '[ "$(grep -c "^FAIL " "$1")" -eq 3 ] && grep -qx "acceptance (rehearsal): 3 automated item(s) FAILED" "$1"' _ "$t/out"

# ===== Part 3: what each check actually reads =========================================================
# update status: a last run that failed, a prefix of the pin, and a last run that succeeded.
U='{"update":{},"channel":{"value":"stable"}'
item_with rehearsal "$I_UPDATE" update "$U"',"lastRun":{"runId":"u1","status":"failed","reason":"x"}}' FAIL
check "update status: the failing last run is named in the tail" out_re "last update run is 'failed'"
item_with rehearsal "$I_UPDATE" update "$U"',"lastRun":{"runId":"u1","status":"succeeded"}}' PASS
item_with rehearsal "$I_UPDATE" version "OpenClaw 2026.9.6 (c074824)" FAIL
check "update status: an older version names both it and the pin in the tail" out_re "installed '2026.9.6' is older than the pin '$pin'"
item_with rehearsal "$I_UPDATE" version "OpenClaw 2026.9 (c074824)" FAIL     # a prefix of the pin is older (2026.9 = 2026.9.0)
item_with rehearsal "$I_UPDATE" version "OpenClaw $pin (c074824)" PASS
item_with rehearsal "$I_UPDATE" version "OpenClaw 2026.9.8 (c074824)" PASS    # newer (after an `openclaw update`)
item_with rehearsal "$I_UPDATE" version "OpenClaw 2026.10.1 (c074824)" PASS   # newer by a multi-digit field: numeric, not lexical
item_with rehearsal "$I_UPDATE" version "OpenClaw ${pin}0 (c074824)" PASS     # 2026.9.70 is newer than 2026.9.7, not "the pin plus junk"
item_with rehearsal "$I_UPDATE" version "OpenClaw 2026.9.7-beta (c074824)" FAIL
item_with rehearsal "$I_UPDATE" version "not a version line" FAIL
check "update status: an unreadable version is named as such, with the pin present" out_re "installed 'unreadable' is not a version"
fresh; rm "$t/repo/provision/versions.env"; acc rehearsal "$LAN"; put_pin
check "update status: no pin to compare with fails the item, not the whole run" only_fails "$I_UPDATE" $((n_reh - 1))
fresh; export FAKE_OUT_version="not a version line"; rm "$t/repo/provision/versions.env"; acc rehearsal "$LAN"; put_pin
check "update status: an unreadable version does not equal a missing pin (both empty must not pass)" \
  bash -c 'grep -qx "FAIL   $1" "$2" && grep -q "no OPENCLAW_VERSION in provision/versions.env" "$2"' _ "$I_UPDATE" "$t/out"

# secrets audit: unresolved=0 is read as a whole count.
item_with rehearsal "$I_AUDIT" audit "Secrets audit: findings. plaintext=1, unresolved=07, shadowed=0, storeResidue=0, legacy=0." FAIL

# agent probes read the reply text only, in either documented shape, whatever the case.
item_with rehearsal "$I_PRIMARY" primary '{"status":"ok","result":{"payloads":[{"text":"Pong."}]}}' PASS
item_with rehearsal "$I_FALLBACK" fallback '{"payloads":[{"text":"pong"}],"meta":{}}' PASS
item_with rehearsal "$I_PRIMARY" primary 'pong' FAIL
item_with rehearsal "$I_PRIMARY" primary '{"status":"ok","result":{"payloads":[]}}' FAIL

# the vault: any sha1 or sha256 HEAD line passes; other words on stdout (an ssh complaint) do not.
item_with rehearsal "$I_VAULT" vault "fatal: could not read from the remote repository" FAIL
item_with rehearsal "$I_VAULT" vault "$(printf 'a%.0s' $(seq 1 64))	HEAD" PASS

# the guard: a dry run that decides to restart is still a guard that ran.
item_with rehearsal "$I_GUARD" guard "[dry-run] 2026-01-01T00:00:00.000Z restart: stranded listener (3 events)" PASS

# WhatsApp: the line as the live Gateway prints it (colour codes stripped, as the guard does), and its near misses.
item_with final "$I_WA" channels "$(printf 'Gateway reachable.\n\n- \033[1mWhatsApp\033[0m default: enabled, configured, \033[32mlinked\033[0m, \033[32mrunning\033[0m, \033[32mconnected\033[0m\n')" PASS
item_with final "$I_WA" channels "- WhatsApp default: enabled, configured, not linked, stopped, disconnected" FAIL
item_with final "$I_WA" channels "- WhatsApp default: enabled, configured, linked, running, disconnected" FAIL
item_with final "$I_WA" channels "- no configured chat channels (run \`openclaw channels list --all\` to see installable channels)" FAIL
check "the WhatsApp line pattern lives in one named constant, for Task 10 to correct in one place" \
  bash -c '[ "$(grep -c "^WA_LINKED_RE=" "$1")" -eq 1 ] && [ "$(grep -v "^[[:space:]]*#" "$1" | grep -c "WhatsApp default")" -eq 1 ]' _ "$here/acceptance.sh"

# ===== Part 4: the probe sessions are always cleaned up ===============================================
del_re='^openclaw sessions delete agent:main:bench:acc-primary agent:main:bench:acc-fallback --agent main --yes \|'
fresh; acc rehearsal "$LAN"
check "healthy: both probe sessions are deleted, after both probes" log_order '--session-key bench:acc-primary' '--session-key bench:acc-fallback' "$del_re"
check "healthy: the sessions are deleted exactly once (the EXIT trap must not repeat it)" \
  bash -c '[ "$(grep -c "^openclaw sessions delete" "$1")" -eq 1 ]' _ "$FAKE_LOG"
fresh; export FAKE_RC_primary=1 FAKE_RC_fallback=1; acc rehearsal "$LAN"
check "both probes failing: the sessions are deleted anyway" log_order '--session-key bench:acc-primary' '--session-key bench:acc-fallback' "$del_re"
check "both probes failing: both are FAIL and every other item ran" \
  bash -c '[ "$(grep -c "^FAIL " "$1")" -eq 2 ] && [ "$(grep -c "^PASS " "$1")" -eq "$2" ]' _ "$t/out" $((n_reh - 2))
fresh; export FAKE_RC_primary=1; acc rehearsal "$LAN"
check "only the first probe failing: the sessions are deleted anyway" log_re "$del_re"
fresh; export FAKE_RC_delete=1; acc rehearsal "$LAN"
check "a failed delete does not fail the acceptance" test "$rc" -eq 0
check "a failed delete says so on stderr: they may not exist, else remove them by hand, naming them" \
  err_re 'could not delete the probe sessions \(they may not exist; if they do, remove them by hand: agent:main:bench:acc-primary agent:main:bench:acc-fallback\)'
check "the delete says nothing on stdout when it works" bash -c '! grep -q "acc-primary" "$1"' _ "$t/out"

# ===== Part 5: the bootstrap token is parsed from ~/.openclaw/.env, never evaluated ===================
# It is read with ops/lib/dotenv-token.sh (shared with import.sh and the nightly), so whatever that refuses,
# this refuses: before any item runs and before any OpenClaw call.
fresh; rm "$t/home/.openclaw/.env"; acc rehearsal "$LAN"
check "a missing .env: exit 1" test "$rc" -eq 1
check "a missing .env: the message names the file and points at import.sh" err_re '\.openclaw/\.env is missing; run migrate/import\.sh first'
check "a missing .env: no item ran and nothing was called" no_items
check "a missing .env: nothing left in TMPDIR" tmp_clean

fresh; printf 'HOME=/x\n' > "$t/home/.openclaw/.env"; acc rehearsal "$LAN"
check "no token line: exit 1 with the shared parser's message" bash -c '[ "$1" -eq 1 ] && grep -q "no OP_SERVICE_ACCOUNT_TOKEN= line" "$2"' _ "$rc" "$t/err"
check "no token line: no item ran and nothing was called" no_items

fresh; export OP_SERVICE_ACCOUNT_TOKEN=inherited-value; printf 'HOME=/x\n' > "$t/home/.openclaw/.env"; acc rehearsal "$LAN"
unset OP_SERVICE_ACCOUNT_TOKEN
check "an inherited token cannot stand in for a missing one" bash -c '[ "$1" -eq 1 ] && grep -q "no OP_SERVICE_ACCOUNT_TOKEN= line" "$2"' _ "$rc" "$t/err"

fresh; printf 'OP_SERVICE_ACCOUNT_TOKEN=a-1\nexport OP_SERVICE_ACCOUNT_TOKEN=b-2\n' > "$t/home/.openclaw/.env"; acc rehearsal "$LAN"
check "a token set twice is refused, not guessed at" bash -c '[ "$1" -eq 1 ] && grep -q "is set 2 times" "$2"' _ "$rc" "$t/err"
check "a refused token: no item ran and nothing was called" no_items

fresh; printf 'OP_SERVICE_ACCOUNT_TOKEN=%s\r\n' "$SA_TOKEN" > "$t/home/.openclaw/.env"; acc rehearsal "$LAN"
check "a CRLF .env is refused" bash -c '[ "$1" -eq 1 ] && grep -q "CRLF" "$2"' _ "$rc" "$t/err"

fresh; printf 'touch %s\nOP_SERVICE_ACCOUNT_TOKEN=%s\n' "$t/pwned" "$SA_TOKEN" > "$t/home/.openclaw/.env"; acc rehearsal "$LAN"
check "the .env is data: a command line in it is not run" test ! -e "$t/pwned"
check "the .env is data: the token line beside it is still used" test "$rc" -eq 0

fresh; acc rehearsal "$LAN"
check "op receives the parsed token in its environment, not in argv" log_re '^op read .* sa=ok'
check "every openclaw call carries the gateway token read from op, in its environment" \
  bash -c 'grep -q "^openclaw " "$1" && ! grep "^openclaw " "$1" | grep -q "gw=no"' _ "$FAKE_LOG"

fresh; export FAKE_OP_FAIL=1; acc rehearsal "$LAN"
check "op failing: exit 1 before any item, with a message" bash -c '[ "$1" -eq 1 ] && grep -q "cannot read the gateway token from 1Password" "$2"' _ "$rc" "$t/err"
check "op failing: no item ran and openclaw was never called" no_items
check "op failing: its own message (which carried the token) is not shown" bash -c '! grep -qF -- "$3" "$1" "$2"' _ "$t/out" "$t/err" "$SA_TOKEN"
check "op failing: nothing left in TMPDIR" tmp_clean
fresh; export FAKE_ERR_op="[WARNING] a newer op is available"; acc rehearsal "$LAN"
check "a warning on op's stderr does not end up in the gateway token" \
  bash -c '[ "$1" -eq 0 ] && grep -q "^openclaw " "$2" && ! grep "^openclaw " "$2" | grep -q "gw=no"' _ "$rc" "$FAKE_LOG"
fresh; export FAKE_OUT_op=""; acc rehearsal "$LAN"
check "op printing nothing: refused before any item" bash -c '[ "$1" -eq 1 ] && grep -q "gateway token read from 1Password is empty" "$2"' _ "$rc" "$t/err"
check "op printing nothing: no item ran and openclaw was never called" no_items

# ===== Part 6: a token in a failing command's output is never printed ==================================
fresh
export FAKE_RC_audit=2
export FAKE_OUT_audit="Secrets audit failed: bad bootstrap $SA_TOKEN, gateway $GW_TOKEN"
export FAKE_ERR_audit="stderr echoes $GW_TOKEN and $SA_TOKEN"
acc rehearsal "$LAN"
check "planted tokens: the item still FAILs, with its tail" bash -c 'grep -qx "FAIL   secrets audit: 0 unresolved" "$1" && grep -q "Secrets audit failed: bad bootstrap \*\*\*, gateway \*\*\*" "$1"' _ "$t/out"
check "planted tokens: neither token is on stdout or stderr" bash -c '! grep -qF -- "$3" "$1" "$2" && ! grep -qF -- "$4" "$1" "$2"' _ "$t/out" "$t/err" "$SA_TOKEN" "$GW_TOKEN"
fresh
export FAKE_RC_vault=1 FAKE_OUT_vault="" FAKE_ERR_vault="fatal: could not read from remote ($GW_TOKEN)"
acc rehearsal "$LAN"
check "planted token in a git error: masked there too" bash -c '! grep -qF -- "$3" "$1" "$2" && grep -q "fatal: could not read from remote (\*\*\*)" "$1"' _ "$t/out" "$t/err" "$GW_TOKEN"

fresh; export FAKE_RC_update=1 FAKE_OUT_update="$GW_TOKEN"; acc final "$LAN"
check "no token on disk: not in HOME, TMPDIR or the repo copy (the .env is where the bootstrap token lives)" \
  bash -c '! grep -rlF -- "$2" "$1/home" "$1/tmp" "$1/repo" && ! grep -rlF --exclude=.env -- "$3" "$1/home" "$1/tmp" "$1/repo"' _ "$t" "$GW_TOKEN" "$SA_TOKEN"
check "no token in any command's argv" bash -c '! grep -qF -- "$2" "$1" && ! grep -qF -- "$3" "$1"' _ "$FAKE_LOG" "$SA_TOKEN" "$GW_TOKEN"

# The tail of a failing item is short and its lines are cut: a whole JSON reply is not dumped on the screen.
twelve=$(printf 'line%s\n' 1 2 3 4 5 6 7 8 9 10 11 12)
fresh; export FAKE_RC_audit=1 FAKE_OUT_audit="$twelve"; acc rehearsal "$LAN"
check "a FAIL shows at most the last five lines of what the item printed" \
  bash -c '[ "$(grep -c "^       " "$1")" -le 5 ] && grep -q "line12" "$1" && ! grep -q "line1$" "$1"' _ "$t/out"
check "a FAIL's tail ends with the reason (the exit status), even when the output alone would fill it" grep -qx "       exit 1" "$t/out"
longline=$(printf 'x%.0s' $(seq 1 500))
fresh; export FAKE_RC_audit=1 FAKE_OUT_audit="$longline"; acc rehearsal "$LAN"
check "a FAIL cuts each line it shows to 200 characters" \
  bash -c 'n=$(( $(grep "^       x" "$1" | head -1 | wc -c) )); [ "$n" -gt 100 ] && [ "$n" -le 210 ]' _ "$t/out"

# ===== Part 7: interrupt and kill ====================================================================
# The probe sessions must not outlive the run however it ends: Ctrl-C and kill leave through the EXIT trap, which
# deletes them once (only if a probe may have started) and removes the temp file. The fakes hold a call for a
# moment (FAKE_HOLD_<key>) so the signal lands while that command is in flight; the script's trap then runs.
deleted_once() { [ "$(grep -c '^openclaw sessions delete' "$FAKE_LOG")" -eq 1 ]; }
no_delete_logged() { ! log_re '^openclaw sessions delete'; }
fresh; acc_signal TERM firewall rehearsal "$LAN"
check "SIGTERM mid-run (after the probes): exit 143" test "$rc" -eq 143
check "SIGTERM mid-run: the probe sessions are deleted, once" deleted_once
check "SIGTERM mid-run: the temp file is gone" tmp_clean
check "SIGTERM mid-run: it says so, and does not claim success" \
  bash -c 'grep -q "^acceptance: terminated$" "$1" && ! grep -q "automated items PASS" "$2"' _ "$t/err" "$t/out"
check "SIGTERM mid-run: nothing after the interrupted item ran" bash -c '! grep -q "^node " "$1"' _ "$FAKE_LOG"
fresh; acc_signal INT firewall rehearsal "$LAN"
check "SIGINT mid-run: exit 130" bash -c '[ "$1" -eq 130 ]' _ "$rc"
check "SIGINT mid-run: sessions deleted once" deleted_once
check "SIGINT mid-run: it says it was interrupted" bash -c 'grep -q "^acceptance: interrupted$" "$1"' _ "$t/err"
check "SIGINT mid-run: nothing is left in TMPDIR" tmp_clean
fresh; acc_signal TERM primary rehearsal "$LAN"
check "SIGTERM during the first probe: the sessions are already deleted, once (the flag is set before the probe)" deleted_once
check "SIGTERM during the first probe: exit 143" bash -c '[ "$1" -eq 143 ]' _ "$rc"
check "SIGTERM during the first probe: the second probe never ran" bash -c '! grep -q "bench:acc-fallback --model" "$1"' _ "$FAKE_LOG"
fresh; acc_signal TERM audit rehearsal "$LAN"
check "SIGTERM before the probes: exit 143" test "$rc" -eq 143
check "SIGTERM before the probes: no delete is asked of openclaw" no_delete_logged
check "SIGTERM before the probes: no probe ran" \
  bash -c '! grep -q "^openclaw agent" "$1"' _ "$FAKE_LOG"
check "SIGTERM before the probes: nothing is left in TMPDIR" tmp_clean
fresh; export FAKE_RC_primary=1 FAKE_RC_fallback=1; acc rehearsal "$LAN"
check "a run that ends normally after failed probes still deletes once, not twice" deleted_once
fresh; rm "$t/home/.openclaw/.env"; acc rehearsal "$LAN"
check "a run that dies before the probes asks openclaw for no delete" no_delete_logged

# `bash -x` or SHELLOPTS=xtrace must not put the tokens on stderr.
fresh; ACC_EXTRA="SHELLOPTS=xtrace"; acc rehearsal "$LAN"
check "under SHELLOPTS=xtrace the run still passes" test "$rc" -eq 0
check "under SHELLOPTS=xtrace neither token is traced onto stderr or stdout" \
  bash -c '! grep -qF -- "$3" "$1" "$2" && ! grep -qF -- "$4" "$1" "$2"' _ "$t/out" "$t/err" "$SA_TOKEN" "$GW_TOKEN"

# ===== Part 9: the bot account items (spec 2026-10-02 §3) ===========================================
# No root: sudo and the firewall table are out of reach.
fresh; acc rehearsal "$LAN"
check "the root check asks sudo -n true, sudo -n -l and the inet claw table" \
  bash -c 'grep -q "^sudo -n true |" "$1" && grep -q "^sudo -n -l |" "$1" && grep -q "^nft list table inet claw |" "$1"' _ "$FAKE_LOG"
fresh; export FAKE_RC_sudotrue=0; acc rehearsal "$LAN"
check "$I_ROOT: sudo -n true succeeding -> FAIL, the rest PASS" only_fails "$I_ROOT" $((n_reh - 1))
check "  ... saying so" out_re 'sudo -n true succeeded'
fresh; export FAKE_RC_sudolist=0; acc rehearsal "$LAN"
check "$I_ROOT: sudo -n -l listing rules -> FAIL" only_fails "$I_ROOT" $((n_reh - 1))
fresh; export FAKE_RC_nft=0; acc rehearsal "$LAN"
check "$I_ROOT: reading the inet claw table -> FAIL" only_fails "$I_ROOT" $((n_reh - 1))
check "  ... naming CAP_NET_ADMIN" out_re 'CAP_NET_ADMIN'
check "$I_ROOT: a readable ruleset is never printed" bash -c '! grep -q "203.0.113.9" "$1"' _ "$t/out"
fresh; export FAKE_RC_nft=0 FAKE_OUT_nft="table inet claw { ip daddr 203.0.113.9 drop }"; acc rehearsal "$LAN"
check "$I_ROOT: the ruleset a bot could read is not printed on the FAIL" bash -c 'grep -qx "FAIL   $1" "$3" && ! grep -q "203.0.113.9" "$3"' _ "$I_ROOT" x "$t/out"
fresh; export FAKE_ERR_nft="Error: No such file or directory"; acc rehearsal "$LAN"
check "$I_ROOT: nft failing for another reason (no such table) -> FAIL, the rest PASS" only_fails "$I_ROOT" $((n_reh - 1))
check "  ... saying the denial is not proven, with nft's first line" out_re 'nft failed for another reason, so the denial is not proven: Error: No such file or directory'
fresh; export FAKE_ERR_nft="netlink: Error: cache initialization failed: operation not permitted"; acc rehearsal "$LAN"
check "$I_ROOT: the netlink wording of the denial, in any case -> PASS" passes "$I_ROOT"
fresh; export FAKE_RC_sudotrue=127; acc rehearsal "$LAN"
check "$I_ROOT: sudo -n true not found (127) -> FAIL, the rest PASS" only_fails "$I_ROOT" $((n_reh - 1))
check "  ... saying the root check cannot run" out_re 'sudo not found or not executable: the root check cannot run'
fresh; export FAKE_RC_sudolist=126; acc rehearsal "$LAN"
check "$I_ROOT: sudo -n -l not executable (126) -> FAIL" only_fails "$I_ROOT" $((n_reh - 1))
fresh; acc rehearsal "$LAN"
check "sudo is only ever called as -n true or -n -l, nft only as list" \
  bash -c '! grep "^sudo " "$1" | grep -qvE "^sudo -n (true|-l) \|" && ! grep "^nft " "$1" | grep -qv "^nft list "' _ "$FAKE_LOG"
if ! (PATH=/usr/sbin:/sbin; command -v nft) >/dev/null 2>&1; then
  fresh; ACC_PATH="$t/nonft"; acc rehearsal "$LAN"
  check "$I_ROOT: nft missing -> FAIL (it cannot be shown), the rest PASS" only_fails "$I_ROOT" $((n_reh - 1))
else
  echo "note: the nft-missing test is skipped, this host has a real nft in /usr/sbin or /sbin"
fi

# Every bot process is this account's: the gateway's main process, and nothing bot-like under another uid.
fresh; acc rehearsal "$LAN"
check "the owner check asks systemd for the gateway's main process, then ps" \
  log_order '^systemctl --user show openclaw-gateway.service -p MainPID --value \|' '^ps -o uid= -p 4242 \|' '^ps -eo pid=,uid=,args= ww \|'
fresh; export FAKE_OUT_mainpid=0; acc rehearsal "$LAN"
check "$I_OWNER: no gateway main process -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
fresh; export FAKE_OUT_psowner=" $other"; acc rehearsal "$LAN"
check "$I_OWNER: the gateway's main process run by another uid -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
for bad in "/usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js gateway --port 18789" "openclaw-gateway" \
           "/usr/local/bin/wacli sync --follow" "/bin/bash /home/other/ops/backup/nightly-backup.sh" \
           "/usr/bin/node /home/other/ops/listener-guard/guard.mjs" "/usr/bin/node /home/other/brain/harvester/harvest.mjs"; do
  fresh; FAKE_OUT_pstable="$(cat "$t/pstable")
 6000 $other $bad"; export FAKE_OUT_pstable; acc rehearsal "$LAN"
  check "$I_OWNER: another account runs [$bad] -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
done
# A uid-0 bot row is another account's too (an admin-started gateway).
fresh; FAKE_OUT_pstable="$(cat "$t/pstable")
 6000 0 /usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js gateway"; export FAKE_OUT_pstable; acc rehearsal "$LAN"
check "$I_OWNER: a root-owned gateway row -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
# Only the culprit is named; unrelated processes' argv (which can carry secrets) never reaches the screen.
fresh; FAKE_OUT_pstable="$(cat "$t/pstable")
 6000 $other /usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js gateway --port 18789
 6001 $other /usr/bin/curl -H token=unrelated-argv-secret https://example.invalid"; export FAKE_OUT_pstable; acc rehearsal "$LAN"
check "$I_OWNER: the FAIL names the culprit's pid and uid" out_re "pid 6000 uid $other: "
check "$I_OWNER: the FAIL does not print unrelated processes' argv" bash -c '! grep -Eq "unrelated-argv-secret|sshd|less /tmp" "$1" "$2"' _ "$t/out" "$t/err"
check "$I_OWNER: the FAIL tells the operator their own tail -f or a concurrent claw.sh can trip it" out_re 'tail -f .*claw\.sh'
# Producer failures, each its own FAIL.
fresh; export FAKE_RC_mainpid=1; acc rehearsal "$LAN"
check "$I_OWNER: systemctl exiting non-zero -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
fresh; export FAKE_RC_psowner=1; acc rehearsal "$LAN"
check "$I_OWNER: ps -o exiting non-zero -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
fresh; export FAKE_OUT_psowner=""; acc rehearsal "$LAN"
check "$I_OWNER: ps -o printing no uid -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
fresh; export FAKE_RC_pstable=1; acc rehearsal "$LAN"
check "$I_OWNER: the process table ps exiting non-zero -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
check "  ... naming the ps exit" out_re 'cannot list processes \(ps exit 1\)'
check "  ... and showing none of the partial table it printed" bash -c '! grep -Eq "sshd|less /tmp|-bash|/sbin/init|index\.js" "$1" "$2"' _ "$t/out" "$t/err"
# A token that straddles the 80th character of the culprit's argv is masked before the cut, never half shown.
pad=$(printf 'x%.0s' $(seq 1 4))
fresh; FAKE_OUT_pstable="$(cat "$t/pstable")
 6000 $other /usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js gateway $pad $SA_TOKEN"; export FAKE_OUT_pstable; acc rehearsal "$LAN"
check "$I_OWNER: a token straddling character 80 of the culprit's argv is FAIL, named" only_fails "$I_OWNER" $((n_reh - 1))
check "  ... and no prefix of the token is shown" bash -c '! grep -qF -- "fixture-" "$1" "$2"' _ "$t/out" "$t/err"
check "  ... the culprit is still named" out_re "pid 6000 uid $other: "
# Positive control: a table without the gateway's own row proves nothing.
fresh; export FAKE_OUT_pstable="    1     0 /sbin/init"; acc rehearsal "$LAN"
check "$I_OWNER: a table without the gateway's own row -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
check "  ... asking whether /proc is hidden" out_re "cannot see the gateway's own process: is /proc hidden"
# Self-validation: the gateway's own row must match BOT_PROC_RE, or a stray gateway under another user could go unseen.
fresh; printf '    1     0 /sbin/init\n 4242 %s /opt/odd/runner serve --token %s\n' "$(id -u)" "$SA_TOKEN" > "$t/pstable-odd"
FAKE_OUT_pstable="$(cat "$t/pstable-odd")"; export FAKE_OUT_pstable; acc rehearsal "$LAN"
check "$I_OWNER: the gateway's own row not matching BOT_PROC_RE -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
check "  ... naming the pattern as the problem" out_re 'BOT_PROC_RE does not match the gateway.s own process'
check "  ... showing the start of the gateway argv" out_re 'gateway argv starts: /opt/odd/runner serve'
check "  ... and never a prefix of the token" bash -c '! grep -qF -- "fixture-" "$1" "$2"' _ "$t/out" "$t/err"
check "the process table is read wide, so COLUMNS cannot cut an argv" log_re '^ps -eo pid=,uid=,args= ww \|'
# The timers must be enabled.
fresh; acc rehearsal "$LAN"
check "the owner check asks whether the guard timer is enabled (the nightly timer: final mode only, below)" \
  bash -c 'grep -q "^systemctl --user is-enabled openclaw-listener-guard.timer |" "$1"' _ "$FAKE_LOG"
fresh; export FAKE_RC_enabled=1; acc rehearsal "$LAN"
check "$I_OWNER: a timer that is not enabled -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
check "  ... naming the timer" out_re 'openclaw-listener-guard\.timer is not enabled'
# The nightly timer is a final-mode unit (import.sh installs the backup units in final mode only): a drill has none.
fresh; export FAKE_RC_enabled_nightly=1; acc rehearsal "$LAN"
check "$I_OWNER: rehearsal without a nightly timer passes the item (R2)" out_has "PASS   $I_OWNER"
check "  ... and the nightly timer is not even asked about in rehearsal" bash -c '! grep -q "is-enabled openclaw-nightly-backup.timer" "$1"' _ "$FAKE_LOG"
check "  ... while the guard timer still is" log_re '^systemctl --user is-enabled openclaw-listener-guard\.timer \|'
fresh; export FAKE_RC_enabled_nightly=1; acc final "$LAN"
check "$I_OWNER: final without a nightly timer -> FAIL (R2)" only_fails "$I_OWNER" $((n_fin - 1))
check "  ... naming the nightly timer" out_re 'openclaw-nightly-backup\.timer is not enabled'

# The guard reads the gateway's log dir; after an in-place move it must be this account's (Review Focus 1).
fresh; rm -rf "$t/gwlog"; acc rehearsal "$LAN"
check "$I_GWLOG: the guard's log dir missing -> FAIL" only_fails "$I_GWLOG" $((n_reh - 1))
fresh; rm -f "$t/gwlog"/*; acc rehearsal "$LAN"
check "$I_GWLOG: no log file of this account -> FAIL" only_fails "$I_GWLOG" $((n_reh - 1))
# A dir that exists, holds this account's own log file, and belongs to someone else: only the owner test can fail it.
# (/tmp is sticky and root's, so a file of ours can sit in it; it is removed at once.)
if [ "$(id -u)" != 0 ] && [ -d /tmp ] && [ ! -O /tmp ]; then
  acclog="/tmp/openclaw-acceptance-test-$$.log"; : > "$acclog"
  fresh; export FAKE_OUT_environment="GUARD_LOG_DIR=/tmp"; acc rehearsal "$LAN"; rm -f "$acclog"; acclog=""
  check "$I_GWLOG: a dir of another user that holds a log of this account -> FAIL" only_fails "$I_GWLOG" $((n_reh - 1))
  check "  ... saying whose logs the guard would read" out_re 'belongs to another user'
else
  echo "note: the other-owner log dir test is skipped (running as root, or /tmp is ours)"
fi
fresh; export FAKE_OUT_environment="FOO=bar GUARD_LOG_DIR=$t/gwlog"; acc rehearsal "$LAN"
check "$I_GWLOG: the dir comes from the unit's Environment, among other variables -> PASS" passes "$I_GWLOG"
fresh; export FAKE_RC_environment=1; acc rehearsal "$LAN"
check "$I_GWLOG: systemctl failing is a FAIL, not a silent fallback" only_fails "$I_GWLOG" $((n_reh - 1))
check "  ... saying so" out_re "cannot read the guard unit's environment \\(systemctl exit 1\\)"
fresh; acc rehearsal "$LAN"
check "the guard's log dir is asked of systemd, not read from a unit file" log_re '^systemctl --user show openclaw-listener-guard.service -p Environment --value \|'
fresh; export FAKE_OUT_environment="FOO=bar"; acc rehearsal "$LAN"
check "$I_GWLOG: no GUARD_LOG_DIR in the unit falls back to /tmp/openclaw (absent here -> FAIL naming it)" \
  bash -c 'grep -qx "FAIL   $1" "$2" && grep -q "/tmp/openclaw" "$2"' _ "$I_GWLOG" "$t/out"

# The memory index's paths.
fresh; acc rehearsal "$LAN"
check "memory status is asked for the main agent" log_re '^openclaw memory status --agent main \|'
item_with rehearsal "$I_MEMORY" memory "workspaceDir: /Users/admin/.openclaw/workspace
dbPath: $t/home/.openclaw/memory/main.sqlite" FAIL
check "  ... naming the stray path" out_re 'memory paths outside .*/Users/admin/\.openclaw/workspace'
item_with rehearsal "$I_MEMORY" memory "workspaceDir: ~/.openclaw/workspace
dbPath: ~/.openclaw/memory/main.sqlite" PASS
item_with rehearsal "$I_MEMORY" memory "workspaceDir: ~/.openclaw/workspace
dbPath: ~/.openclaw/memory/main.sqlite
sessionsDir: /Users/admin/data/sessions" FAIL
check "  ... naming the stray /Users path" out_re 'memory paths outside .*/Users/admin/data/sessions'
item_with rehearsal "$I_MEMORY" memory "workspaceDir: ~/.openclaw/workspace
sessionsDir: /home/other/x" FAIL
item_with rehearsal "$I_MEMORY" memory "workspaceDir: $t/home/.openclaw/workspace
sessionsDir: $t/home/data/sessions" PASS
both_ways rehearsal "$I_MEMORY" memory "Memory search is disabled."

# The guard replay and the refusal, on the installed guard with the committed fixture.
fresh; acc rehearsal "$LAN"
check "the replay reads the committed fixture through the installed guard, with a scratch state file" \
  log_re "^node $t/home/ops/listener-guard/guard.mjs --dry-run --now 2026-09-30T09:02:00Z \\| logdir=.*/ops/listener-guard/fixtures/stranded-listener state=set "
check "the refusal is asked of the installed guard, with --now and no --dry-run" \
  log_re "^node $t/home/ops/listener-guard/guard.mjs --now 2026-09-30T09:02:00Z \\| logdir=.*/ops/listener-guard/fixtures/stranded-listener state=set "
check "the replay and the refusal leave nothing in TMPDIR" tmp_clean
item_with rehearsal "$I_REPLAY" replay "[dry-run] 2026-09-30T09:02:00.000Z skip: WhatsApp not linked (2 events)" PASS
item_with final "$I_REPLAY" replay "[dry-run] 2026-09-30T09:02:00.000Z skip: WhatsApp not linked (2 events)" FAIL
item_with rehearsal "$I_REPLAY" replay "[dry-run] 2026-09-30T09:02:00.000Z restart: stranded listener (2 events)" FAIL
check "  ... saying the drill reports WhatsApp linked" out_re 'the drill reports WhatsApp linked: its credentials were not stripped'
fresh; acc final "$LAN"
check "$I_REPLAY: final still wants the restart decision" passes "$I_REPLAY"
fresh; export FAKE_REPLAY_RESTARTS=1; acc final "$LAN"
check "$I_REPLAY: a guard that runs its restart command on a dry-run replay -> FAIL (only the stub ran)" only_fails "$I_REPLAY" $((n_fin - 1))
check "  ... saying so" out_re 'ran its restart command during a dry-run replay'
check "  ... and the stub's marker is gone" tmp_clean
check "the replay hands the guard a restart stub" log_re "^node .*--dry-run --now " 
item_with rehearsal "$I_REPLAY" replay "ok: 0 event(s) in window" FAIL
item_with rehearsal "$I_REPLAY" replay "[dry-run] 2026-09-30T09:02:00.000Z skip: cooldown (2 events)" FAIL
item_with rehearsal "$I_REPLAY" replay "[dry-run] 2026-09-30T09:02:00.000Z skip: WhatsApp status unknown (2 events)" FAIL
both_ways rehearsal "$I_REPLAY" replay "[dry-run] 2026-09-30T09:02:00.000Z restart: stranded listener (1 events)"
fresh; export FAKE_RC_refuse=0 FAKE_ERR_refuse=""; acc rehearsal "$LAN"
check "$I_REFUSE: a guard that accepts --now without --dry-run -> FAIL" only_fails "$I_REFUSE" $((n_reh - 1))
fresh; export FAKE_REFUSE_RESTARTS=1; acc rehearsal "$LAN"
check "$I_REFUSE: a guard that runs its restart command on a replay -> FAIL (only the stub ran)" only_fails "$I_REFUSE" $((n_reh - 1))
check "  ... saying so" out_re 'ran its restart command on replayed history'
check "  ... and the stub's marker is gone" tmp_clean
fresh; export FAKE_ERR_refuse="node: crashed"; acc rehearsal "$LAN"
check "$I_REFUSE: a non-zero exit for another reason -> FAIL" only_fails "$I_REFUSE" $((n_reh - 1))

# ===== Part 8: usage and dependencies ===============================================================
fresh; acc
check "no arguments: exit 2 with the usage, nothing called" bash -c '[ "$1" -eq 2 ] && grep -q "^usage: .*acceptance.sh rehearsal|final <lan-ip>$" "$2"' _ "$rc" "$t/err"
check "no arguments: nothing was called" test ! -s "$FAKE_LOG"
fresh; acc bogus "$LAN"
check "an unknown mode: exit 2, nothing called" bash -c '[ "$1" -eq 2 ] && [ ! -s "$2" ]' _ "$rc" "$FAKE_LOG"
fresh; acc rehearsal
check "no LAN address: exit 2 (there is no default), nothing called" bash -c '[ "$1" -eq 2 ] && [ ! -s "$2" ]' _ "$rc" "$FAKE_LOG"
fresh; acc rehearsal "$LAN" extra
check "a stray extra argument: exit 2, nothing called" bash -c '[ "$1" -eq 2 ] && [ ! -s "$2" ]' _ "$rc" "$FAKE_LOG"
# The LAN argument must be a dotted-quad IPv4 address (octets 0-255): firewall-check.sh puts it into a bash -c string.
for bad in 1.2.3 256.1.1.1 '1.2.3.4;id' 1.2.3.4.5 01.2.3.4 lan.example; do
  fresh; acc rehearsal "$bad"
  check "LAN argument '$bad': exit 2 with the usage and the reason" \
    bash -c '[ "$1" -eq 2 ] && grep -q "is not a dotted-quad IPv4 address" "$2" && grep -q "^usage: " "$2"' _ "$rc" "$t/err"
  check "LAN argument '$bad': nothing ran and nothing was called" bash -c '[ ! -s "$1" ] && ! grep -Eq "^(PASS|FAIL|MANUAL) " "$2"' _ "$FAKE_LOG" "$t/out"
done
# 0.x and 127.x are this machine, not the LAN: a "blocked" there proves nothing (final review, minor #54).
for bad in 0.0.0.0 127.0.0.1 0.1.2.3 127.255.255.254; do
  fresh; acc rehearsal "$bad"
  check "LAN argument '$bad': exit 2, named as not a LAN address" \
    bash -c '[ "$1" -eq 2 ] && grep -q "is not a LAN address" "$2" && grep -q "^usage: " "$2"' _ "$rc" "$t/err"
  check "LAN argument '$bad': nothing ran and nothing was called" bash -c '[ ! -s "$1" ] && ! grep -Eq "^(PASS|FAIL|MANUAL) " "$2"' _ "$FAKE_LOG" "$t/out"
done
for good in 192.0.2.10 10.0.0.1 255.255.255.255; do
  fresh; acc rehearsal "$good"
  check "LAN argument '$good' is accepted and reaches the firewall check unchanged" bash -c '[ "$1" -eq 0 ] && grep -q "^firewall-check $2 |" "$3"' _ "$rc" "$good" "$FAKE_LOG"
done
check "the script has no IP address, user name or LAN default of its own" \
  bash -c '! grep -Eq "([0-9]{1,3}\.){3}[0-9]{1,3}|/Users/|/home/[a-z]" "$1"' _ "$here/acceptance.sh"

fresh; ACC_PATH="$t/bin:$t/nojq"; acc rehearsal "$LAN"
check "jq missing: exit 1 with the reason, before any item" bash -c '[ "$1" -eq 1 ] && grep -q "jq not found" "$2"' _ "$rc" "$t/err"
check "jq missing: no item ran and nothing was called" no_items

echo "acceptance script: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
