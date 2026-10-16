#!/bin/bash
# Tests for migrate/rehome.sh: the real script, staged in a scratch repo with stub import.sh and acceptance.sh, against
# fakes on PATH: sudo (runs the rest here as the test user, maps the bot's home onto a scratch dir, and tells the other
# fakes whose command it is), systemctl (one fake user manager per account, unit states in files), loginctl, getent,
# tailscale, df, install, chown and date. admin's home is a scratch HOME. Nothing reaches a real guest.
# Runs under /bin/bash 3.2 as well.
# shellcheck disable=SC2016  # bash -c snippets are single-quoted on purpose
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
pass=0; fail=0
check() { # check <description> <cmd...>: the command must succeed
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $desc"; { sed 's/^/    out: /' "$t/out" | tail -8; } 2>/dev/null || true; fi
}
rc=0
ev() { grep -Eq -- "$1" "$t/ev"; }
evF() { grep -qF -- "$1" "$t/ev"; }
in_order() { # in_order <ERE>...: the first event matching each pattern comes after the first matching the one before
  local prev=0 n pat
  for pat in "$@"; do
    n=$(grep -nE -- "$pat" "$t/ev" | head -1 | cut -d: -f1)
    if [ -z "$n" ] || [ "$n" -le "$prev" ]; then return 1; fi
    prev=$n
  done
}

# ===== the staged repo: the real script, stub import and acceptance =====
mkdir -p "$t/repo/migrate/lib" "$t/repo/tests" "$t/repo/provision" "$t/bin" "$t/tmp"
cp "$here/rehome.sh" "$t/repo/migrate/"; cp "$repo/provision/bot.sh" "$t/repo/provision/"
# prepare's dry leftover scan runs the real home rewrite and scan (node, as import.test.sh does), on the shared root list.
cp "$here/homepaths.mjs" "$here/scan-refs.mjs" "$here/binpaths.mjs" "$here/scan-allow.txt" "$t/repo/migrate/"; cp "$here/lib/home-roots.sh" "$t/repo/migrate/lib/"
cat > "$t/repo/migrate/import.sh" <<'EOF'
#!/bin/bash
# Stub import: records who ran it and what it saw, then lays down a bot state the way a real import would.
echo "import $* | as=${FAKE_AS:-admin} home=$HOME xdg=${XDG_RUNTIME_DIR:-} dbus=${DBUS_SESSION_BUS_ADDRESS:-} pwd=$(pwd) admin_gw=$(cat "$FAKE_SD/admin/openclaw-gateway.service" 2>/dev/null) gwlog=$([ -e "$FAKE_GWLOG" ] && echo present || echo absent)" >> "$FAKE_LOG"
[ "${FAKE_IMPORT_RC:-0}" = 0 ] || exit "$FAKE_IMPORT_RC"
mkdir -p "$HOME/.openclaw" "$HOME/.wacli" "$HOME/.config/systemd/user" "$HOME/brain"
echo '{}' > "$HOME/.openclaw/openclaw.json"
if [ "$1" = final ]; then
  mkdir -p "$HOME/.openclaw/credentials/whatsapp/default"
  echo bot-creds > "$HOME/.openclaw/credentials/whatsapp/default/creds.json"
  for f in session.db session.db-wal; do echo "bot-$f" > "$HOME/.wacli/$f"; done
fi
for u in openclaw-gateway.service openclaw-listener-guard.service openclaw-listener-guard.timer openclaw-nightly-backup.service openclaw-nightly-backup.timer; do
  echo "[Unit]" > "$HOME/.config/systemd/user/$u"
done
mkdir -p "$FAKE_SD/bot"; echo active > "$FAKE_SD/bot/openclaw-gateway.service"
EOF
cat > "$t/repo/tests/acceptance.sh" <<'EOF'
#!/bin/bash
echo "acceptance $* | as=${FAKE_AS:-admin} home=$HOME xdg=${XDG_RUNTIME_DIR:-}" >> "$FAKE_LOG"
exit "${FAKE_ACC_RC:-0}"
EOF

# ===== fakes =====
cat > "$t/bin/sudo" <<'EOF'
#!/bin/bash
# Fake sudo: logs the call, then runs the command here as the test user, with the bot's home mapped onto
# $FAKE_BOT_HOME. FAKE_AS tells the other fakes whose command it is (bot or root).
echo "sudo $*" >> "$FAKE_LOG"
as=root
while [ $# -gt 0 ]; do
  case "$1" in
    -n) shift ;;
    -u) as=bot; shift 2 ;;
    -l) printf '%b\n' "${FAKE_SUDO_LIST:-User sebastian is not allowed to run sudo on claw.}"; exit 1 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
args=(); for a in "$@"; do args+=("${a//\/home\/sebastian/$FAKE_BOT_HOME}"); done
set -- "${args[@]}"
if [ "$1" = env ] && [ "${2:-}" = -C ]; then cd "$3" || exit 1; shift 3; set -- env "$@"; fi
export FAKE_AS="$as"
exec "$@"
EOF
cat > "$t/bin/systemctl" <<'EOF'
#!/bin/bash
# Fake systemd user managers, one per account (FAKE_AS=bot from the fake sudo, else admin's), unit states in $FAKE_SD.
who=admin; if [ "${FAKE_AS:-}" = bot ]; then who=bot; fi
echo "systemctl as=$who $*" >> "$FAKE_LOG"
[ "$1" = --user ] || exit 0
shift
d="$FAKE_SD/$who"; mkdir -p "$d"
case "$1" in
  disable) shift; if [ "$1" = --now ]; then shift; fi; for u in "$@"; do echo inactive > "$d/$u"; done ;;
  enable)  shift; if [ "$1" = --now ]; then shift; fi; for u in "$@"; do echo active > "$d/$u"; done ;;
  is-active)
    st=$(cat "$d/$2" 2>/dev/null || echo inactive)
    if [ "${FAKE_STUCK:-}" = "$who:$2" ]; then st=activating; fi
    echo "$st"; [ "$st" = active ]; exit $? ;;
  start)
    if [ "$2" = openclaw-nightly-backup.service ]; then
      [ -z "${FAKE_NIGHTLY_FAIL:-}" ] || exit 1
      n="$HOME/backups/claw-nightly-${FAKE_NIGHT_TS:-$FAKE_TS}"
      mkdir -p "$n"; for f in MANIFEST openclaw-backup.tar.gz filestate.tar.gz; do echo "$f" > "$n/$f"; done
      # The OpenClaw CLI the nightly runs as admin recreates the gateway log dir (real guest: admin 700): a marker stands for that.
      mkdir -p "$FAKE_GWLOG"; echo admin > "$FAKE_GWLOG/.born-as-admin"
    fi ;;
  show) echo "${FAKE_NIGHTLY_RESULT:-success}" ;;
  daemon-reload) # admin's reload precedes enabling its units: FAKE_BOT_REVIVE has the bot's gateway come back by then
    if [ -n "${FAKE_BOT_REVIVE:-}" ] && [ "$who" = admin ]; then mkdir -p "$FAKE_SD/bot"; echo active > "$FAKE_SD/bot/openclaw-gateway.service"; fi ;;
esac
exit 0
EOF
cat > "$t/bin/flock" <<'EOF'
#!/bin/bash
echo "flock $*" >> "$FAKE_LOG"
[ -z "${FAKE_LOCK_HELD:-}" ]   # a lock another run holds: -n fails at once
EOF
cat > "$t/bin/mv" <<'EOF'
#!/bin/bash
# Fake mv: FAKE_MV_FAIL=<suffix> makes a move whose source ends in it fail (a retire dying half-way); else the real one.
if [ -n "${FAKE_MV_FAIL:-}" ] && [ "$#" -ge 2 ]; then
  case "${*: -2:1}" in *"$FAKE_MV_FAIL") echo "mv: fake failure" >&2; exit "${FAKE_MV_RC:-1}" ;; esac
fi
exec /bin/mv "$@"
EOF
cat > "$t/bin/tar" <<'EOF'
#!/bin/bash
# Fake tar: logs its argv, then the real one. FAKE_TAR_CREATE_RC makes a create (-c) end with that status after doing its
# work (GNU tar's exit 1, "file changed as we read it"); FAKE_TAR_EXTRACT_FAIL makes an extract (-x) fail.
echo "tar $*" >> "$FAKE_LOG"
case "$1" in
  -x*) [ -z "${FAKE_TAR_EXTRACT_FAIL:-}" ] || { cat >/dev/null; exit 2; } ;;
esac
/usr/bin/tar "$@"; rc=$?
case "$1" in -c*) [ -z "${FAKE_TAR_CREATE_RC:-}" ] || exit "$FAKE_TAR_CREATE_RC" ;; esac
exit "$rc"
EOF
cat > "$t/bin/loginctl" <<'EOF'
#!/bin/bash
echo "loginctl $*" >> "$FAKE_LOG"
if [ "$1" = show-user ]; then echo "Linger=${FAKE_BOT_LINGER:-yes}"; fi
EOF
cat > "$t/bin/getent" <<'EOF'
#!/bin/bash
if [ "$1 $2" = "passwd sebastian" ]; then echo "sebastian:x:${FAKE_BOT_IDS:-2000:2000}::/home/sebastian:/bin/bash"; else exit 2; fi
EOF
cat > "$t/bin/tailscale" <<'EOF'
#!/bin/bash
if [ "$1 ${2:-}" = "debug prefs" ]; then echo "{\"OperatorUser\":\"${FAKE_TS_OPERATOR-sebastian}\"}"; fi
EOF
cat > "$t/bin/df" <<'EOF'
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 1000000000 1 ${FAKE_DF_AVAIL_KB:-100000000} 1% /"
EOF
cat > "$t/bin/install" <<'EOF'
#!/bin/bash
# Fake install: logs, then the real one without -o/-g (the test user cannot hand files to root or the bot).
echo "install $*" >> "$FAKE_LOG"
args=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
exec /usr/bin/install "${args[@]}"
EOF
printf '#!/bin/bash\necho "chown $*" >> "$FAKE_LOG"\n' > "$t/bin/chown"
cat > "$t/bin/openclaw" <<'EOF'
#!/bin/bash
# Fake openclaw: `cron list --all --json` prints FAKE_CRON_JSON (default: a list of 21) and exits FAKE_CRON_RC (default 0);
# as the bot (its gateway's view, read by verify), FAKE_BOT_CRON_JSON and FAKE_BOT_CRON_RC instead (same defaults).
echo "openclaw as=${FAKE_AS:-admin} $*" >> "$FAKE_LOG"
if [ "$*" = "cron list --all --json" ]; then
  # FAKE_CRON_NULLS / FAKE_BOT_CRON_NULLS=k: the first k reads (counted in the log, this one included) answer {"total":null}.
  nth=$(grep -c "^openclaw as=${FAKE_AS:-admin} cron list --all --json\$" "$FAKE_LOG")
  if [ "${FAKE_AS:-}" = bot ]; then
    if [ "$nth" -le "${FAKE_BOT_CRON_NULLS:-0}" ]; then echo '{"total":null}'; exit 0; fi
    if [ -n "${FAKE_BOT_CRON_JSON+x}" ]; then printf '%s\n' "$FAKE_BOT_CRON_JSON"; else echo '{"total":21,"jobs":[]}'; fi
    exit "${FAKE_BOT_CRON_RC:-0}"
  fi
  if [ "$nth" -le "${FAKE_CRON_NULLS:-0}" ]; then echo '{"total":null}'; exit 0; fi
  if [ -n "${FAKE_CRON_JSON+x}" ]; then printf '%s\n' "$FAKE_CRON_JSON"; else echo '{"total":21,"jobs":[]}'; fi
  exit "${FAKE_CRON_RC:-0}"
fi
EOF
cat > "$t/bin/python3" <<'EOF'
#!/bin/bash
# Fake python3 (migrate/state-paths.py; state-paths.test.py tests the real one): preflight logs its TMPDIR and exits
# FAKE_PREFLIGHT_RC, check exits FAKE_CHECK_RC (default 0 both).
if [ "${2:-}" = preflight ]; then
  echo "python3 as=${FAKE_AS:-admin} $* | tmpdir=${TMPDIR:-}" >> "$FAKE_LOG"
  if [ "${FAKE_PREFLIGHT_RC:-0}" != 0 ]; then echo "state-paths preflight: refused: simulated" >&2; fi
  exit "${FAKE_PREFLIGHT_RC:-0}"
fi
echo "python3 as=${FAKE_AS:-admin} $*" >> "$FAKE_LOG"
exit "${FAKE_CHECK_RC:-0}"
EOF
cat > "$t/bin/date" <<'EOF'
#!/bin/bash
case "$*" in
  "-u +%Y%m%dT%H%M%SZ") echo "$FAKE_TS" ;;
  "-u +%Y%m%d") echo "$FAKE_DAY" ;;
  "-u -d +14 days +%Y-%m-%d") echo "$FAKE_DEL" ;;
  *) exec /bin/date "$@" ;;
esac
EOF
chmod +x "$t/bin/"* "$t/repo/migrate/"*.sh "$t/repo/tests/"*.sh

A="$t/admin"; B="$t/bot"; R="$t/varlib/claw-retired-admin-20261002"
fresh() { # production as admin runs it: admin's state, units active, gateway logs in $t/gwlog; a ready, empty bot home
  unset FAKE_IMPORT_RC FAKE_ACC_RC FAKE_NIGHTLY_FAIL FAKE_NIGHTLY_RESULT FAKE_NIGHT_TS FAKE_STUCK FAKE_MV_FAIL FAKE_MV_RC FAKE_LOCK_HELD FAKE_BOT_REVIVE FAKE_TAR_CREATE_RC FAKE_TAR_EXTRACT_FAIL FAKE_SUDO_LIST FAKE_BOT_IDS FAKE_BOT_LINGER FAKE_TS_OPERATOR FAKE_DF_AVAIL_KB TS FAKE_CRON_JSON FAKE_CRON_RC FAKE_CHECK_RC FAKE_BOT_CRON_JSON FAKE_BOT_CRON_RC FAKE_PREFLIGHT_RC FAKE_CRON_NULLS FAKE_BOT_CRON_NULLS || true
  rm -rf "$A" "$B" "$t/varlib" "$t/sd" "$t/gwlog" "$t"/gwlog.* "$t/tmp"; mkdir -p "$t/tmp"; : > "$t/ev"
  mkdir -p "$A/.openclaw/credentials/whatsapp/default" "$A/.wacli" "$A/.ssh" "$A/brain/vault" "$A/ops" "$A/.openclaw-stale-1" \
    "$A/backups/claw-nightly-20261001T033000Z" "$A/.config/systemd/user" "$B" "$t/varlib" "$t/gwlog" "$t/sd/admin"
  echo '{"gateway":{"tailscale":{"mode":"serve"}}}' > "$A/.openclaw/openclaw.json"
  echo admin-creds > "$A/.openclaw/credentials/whatsapp/default/creds.json"
  for f in session.db session.db-shm; do echo "admin-$f" > "$A/.wacli/$f"; done
  echo 'ssh-ed25519 AAAAlima lima' > "$A/.ssh/authorized_keys"; echo key > "$A/.ssh/ocsb_vault"; echo cfg > "$A/.ssh/config"
  for u in openclaw-gateway.service openclaw-listener-guard.service openclaw-listener-guard.timer openclaw-nightly-backup.service openclaw-nightly-backup.timer; do
    echo "[Unit]" > "$A/.config/systemd/user/$u"
  done
  for u in openclaw-gateway.service openclaw-listener-guard.timer openclaw-nightly-backup.timer; do echo active > "$t/sd/admin/$u"; done
  echo old-line > "$t/gwlog/openclaw-2026-10-01.log"
}
rh() { # rh <phase args...>: the staged rehome.sh as "admin" (the test user, HOME=$A); output $t/out, status $rc
  set +e
  env -u CLAW_INSTANCE HOME="$A" FAKE_LOG="$t/ev" FAKE_BOT_HOME="$B" FAKE_SD="$t/sd" FAKE_GWLOG="$t/gwlog" \
    FAKE_TS="${TS:-20261002T120000Z}" FAKE_DAY="${DAY:-20261002}" FAKE_DEL=2026-10-16 \
    REHOME_VARLIB="$t/varlib" REHOME_LOCK="${LOCKP:-$t/lock}" REHOME_GW_LOGDIR="$t/gwlog" REHOME_SCRATCHDIR="$t/tmp" REHOME_CRON_RETRIES="${RETRIES:-12}" REHOME_CRON_RETRY_SLEEP=0 TMPDIR="${RH_TMPDIR:-$t/tmp}" PATH="$t/bin:$PATH" \
    bash "$t/repo/migrate/rehome.sh" "$@" >"$t/out" 2>&1
  rc=$?
  set -e
}
refuses() { # refuses <description> <output ERE> <phase args...>: exit 1 with that message
  local desc="$1" pat="$2"; shift 2
  rh "$@"
  if [ "$rc" -eq 1 ] && grep -Eq -- "$pat" "$t/out"; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $desc (rc=$rc)"; sed 's/^/    out: /' "$t/out" | tail -6; fi
}
snap() { (cd "$1" && find . | sort && find . -type f | sort | while read -r f; do cksum "$f"; done); }   # a tree's names, modes-free content sums
scratch_gone() { [ -z "$(ls -A "$t/tmp")" ]; }
st_of() { cat "$t/sd/$1/$2" 2>/dev/null || echo inactive; }   # st_of admin|bot <unit>

# ===== usage =====
fresh; rh; check "no phase: usage, exit 2" test "$rc" -eq 2
fresh; rh switch; check "switch without a mode: usage" test "$rc" -eq 2
fresh; rh switch rehearsal; check "switch takes final or drill, nothing else" test "$rc" -eq 2
fresh; rh verify final; check "verify without a LAN address: usage" test "$rc" -eq 2

# ===== prepare =====
fresh; rh prepare
check "prepare passes on a ready bot account and changes nothing" \
  bash -c '[ "$1" -eq 0 ] && grep -q "^prepare: OK" "$2" && [ ! -e "$3/claw-rehome" ] && [ "$(cat "$4/admin/openclaw-gateway.service")" = active ]' _ "$rc" "$t/out" "$t/varlib" "$t/sd"
check "  ... and looked inside the bot's home through sudo (Review Focus 5)" evF 'sudo -n test -e /home/sebastian/.openclaw'
fresh; export FAKE_BOT_IDS=2000:1000; refuses "prepare refuses a bot account with the wrong gid" "is not 2000:2000" prepare
fresh; export FAKE_SUDO_LIST='User sebastian may run the following commands on claw:\n    (ALL) NOPASSWD: ALL'
refuses "prepare refuses a bot account that may run sudo" "may run sudo" prepare
fresh; export FAKE_BOT_LINGER=no; refuses "prepare refuses a bot account without linger" "no linger" prepare
fresh; mkdir -p "$B/.openclaw"; refuses "prepare refuses when the bot already has state, seen through sudo (Review Focus 5)" "exists already" prepare
fresh; mkdir -p "$B/.ssh"; echo k > "$B/.ssh/authorized_keys"; refuses "prepare refuses an SSH login key in the bot's home" "must have no SSH login" prepare
fresh; export FAKE_TS_OPERATOR=; refuses "prepare refuses serve mode without the bot as Tailscale operator" "operator to be sebastian, not 'none'" prepare
fresh; echo '{"gateway":{"tailscale":{"mode":"off"}}}' > "$A/.openclaw/openclaw.json"; export FAKE_TS_OPERATOR=; rh prepare
check "prepare does not need the operator when serve is off" test "$rc" -eq 0
fresh; export FAKE_DF_AVAIL_KB=10; refuses "prepare refuses a disk that cannot hold the switch" "not enough free space" prepare
fresh; rm "$A/.config/systemd/user/openclaw-nightly-backup.service"; refuses "prepare refuses when admin has no nightly unit" "no openclaw-nightly-backup.service" prepare

# ===== prepare: the dry leftover scan of admin's live state (controller ruling, Task 4 review) =====
fresh; snap "$A" > "$t/snap.before"; rh prepare; snap "$A" > "$t/snap.after"
check "prepare's scan leaves admin's files byte-identical and its scratch copy gone" bash -c 'cmp -s "$1" "$2" && [ -z "$(ls -A "$3")" ]' _ "$t/snap.before" "$t/snap.after" "$t/tmp"
fresh; echo "{\"p\":\"$A/x\"}" > "$A/ops/c.json"; echo "SECRETLINE $A/bin" > "$A/brain/vault/n.txt"; rh prepare
check "a JSON file naming admin's home is rewritten on the copy, and the vault is not scanned: prepare passes" test "$rc" -eq 0
check "  ... and admin's own JSON still names its home (the copy was rewritten, not admin's)" grep -qF "$A/x" "$A/ops/c.json"
fresh; echo "SECRETLINE $A/bin" > "$A/ops/note.txt"; snap "$A" > "$t/snap.before"
refuses "a text file naming admin's home that homepaths cannot rewrite fails prepare" "prepare: admin's live configuration still names $A \\(see above\\): make it home-relative at the source, or teach migrate/homepaths.mjs that file" prepare
snap "$A" > "$t/snap.after"
check "  ... the scratch copy is gone, admin's files are unchanged, and no file content was printed" \
  bash -c 'cmp -s "$1" "$2" && [ -z "$(ls -A "$3")" ] && ! grep -q SECRETLINE "$4"' _ "$t/snap.before" "$t/snap.after" "$t/tmp" "$t/out"
check "  ... and it failed before 'prepare: OK'" bash -c '! grep -q "^prepare: OK" "$1"' _ "$t/out"
fresh; printf 'console.log("scan-refs stub: broken");\nprocess.exit(3);\n' > "$t/repo/migrate/scan-refs.mjs"
refuses "a scan that cannot run fails prepare with its exit code and last line" "the leftover scan could not run \\(exit 3: scan-refs stub: broken\\)" prepare
check "  ... the scratch copy is gone" scratch_gone
cp "$here/scan-refs.mjs" "$t/repo/migrate/scan-refs.mjs"
fresh; printf 'process.exit(2);\n' > "$t/repo/migrate/homepaths.mjs"; rh prepare
check "a home rewrite that fails fails prepare, scratch gone" bash -c '[ "$1" -eq 1 ] && [ -z "$(ls -A "$2")" ]' _ "$rc" "$t/tmp"
cp "$here/homepaths.mjs" "$t/repo/migrate/homepaths.mjs"
fresh; rh prepare
check "the brain copy for the scan excludes the vault, .git and node_modules" \
  evF 'tar -cf - --exclude=./vault --exclude=.git --exclude=node_modules .'
check "  ... and extracts into a claw-rehome-scan.* directory under the scratch knob" ev "^tar -xf - -C $t/tmp/claw-rehome-scan\\.[A-Za-z0-9]+/brain$"
fresh; mkdir -p "$A/brain/.git" "$A/brain/vault/v"; echo gitsecret > "$A/brain/.git/config"; echo v > "$A/brain/vault/v/n"
rh prepare; check "  ... and admin's brain is untouched by it" bash -c '[ "$1" -eq 0 ] && [ -f "$2/brain/.git/config" ] && [ -f "$2/brain/vault/v/n" ]' _ "$rc" "$A"
fresh; export FAKE_TAR_CREATE_RC=1; rh prepare
check "GNU tar's exit 1 on the brain copy is tolerated, said so, and prepare passes" \
  bash -c '[ "$1" -eq 0 ] && grep -qF "prepare: brain changed during the dry-scan copy (harmless for the scan)" "$2" && grep -q "^prepare: OK" "$2"' _ "$rc" "$t/out"
check "  ... scratch gone" scratch_gone
fresh; export FAKE_TAR_CREATE_RC=2; refuses "a tar exit of 2 on the brain copy is fatal" "cannot copy $A/brain for the leftover scan" prepare
check "  ... scratch gone" scratch_gone
fresh; export FAKE_TAR_EXTRACT_FAIL=1; refuses "a failing extract side of the brain copy is fatal" "cannot copy $A/brain for the leftover scan" prepare
check "  ... scratch gone" scratch_gone

# ===== prepare: the import's memory-note walk over admin's live workspaces (fix round 1, minor 4) =====
fresh; mkdir -p "$A/.openclaw/workspace/memory"; printf '<!-- project: path:%s/.openclaw/workspace -->\n' "$A" > "$A/.openclaw/workspace/memory/n.md"
rh prepare
check "prepare walks admin's workspace notes as the import's rewrite will, and passes, changing nothing" \
  bash -c '[ "$1" -eq 0 ] && grep -qF "homepaths: 1 memory note(s) in 1 workspace(s), no symlinked directory" "$2" && grep -qxF "<!-- project: path:$3/.openclaw/workspace -->" "$3/.openclaw/workspace/memory/n.md"' _ "$rc" "$t/out" "$A"
fresh; mkdir -p "$A/.openclaw/workspace/memory" "$A/elsewhere"; ln -s "$A/elsewhere" "$A/.openclaw/workspace/memory/linked"
refuses "a symlinked directory in admin's workspace fails prepare, as it would fail the import's note rewrite mid-downtime" \
  "workspace/memory/linked is a symlinked directory" prepare
check "  ... with the advice, and no OK" \
  bash -c 'grep -q "prepare: a workspace of admin.s holds what the import.s note rewrite refuses (see above)" "$1" && ! grep -q "^prepare: OK" "$1"' _ "$t/out"

# ===== prepare: the state-path preflight (fix round 1, I3): what would refuse mid-downtime refuses here =====
fresh; rh prepare
check "prepare runs the state-path preflight as admin on admin's home, its scratch under the scratch knob, and passes" \
  bash -c '[ "$1" -eq 0 ] && grep -qxF "python3 as=admin $2/repo/migrate/state-paths.py preflight --home $3 | tmpdir=$2/tmp" "$4"' _ "$rc" "$t" "$A" "$t/ev"
check "  ... before 'prepare: OK'" bash -c '[ "$(grep -c "^prepare: OK" "$1")" -eq 1 ]' _ "$t/out"
fresh; RH_TMPDIR="$A/tmp" rh prepare
check "  ... in the scratch knob even when admin's TMPDIR is elsewhere (its home)" \
  grep -qxF "python3 as=admin $t/repo/migrate/state-paths.py preflight --home $A | tmpdir=$t/tmp" "$t/ev"
fresh; export FAKE_PREFLIGHT_RC=1
refuses "a refusing preflight fails prepare, production untouched" \
  "prepare: the state-path preflight refused \\(see above\\): fix it while production runs; production untouched" prepare
check "  ... with its own reason shown, and no OK" bash -c 'grep -q "state-paths preflight: refused: simulated" "$1" && ! grep -q "^prepare: OK" "$1"' _ "$t/out"
fresh; export FAKE_PREFLIGHT_RC=1
refuses "a refusing preflight stops the switch" "the state-path preflight refused" switch final
check "  ... before admin's automation count is read or any of admin's units is stopped" \
  bash -c '! grep -Eq "cron list|disable --now|start openclaw-nightly-backup|^import " "$1" && [ "$(cat "$2/admin/openclaw-gateway.service")" = active ] && [ ! -e "$3/claw-rehome" ]' _ "$t/ev" "$t/sd" "$t/varlib"

# ===== switch =====
fresh; rh switch final
check "switch final completes" bash -c '[ "$1" -eq 0 ] && grep -q "^switch: done (final, claw-nightly-20261002T120000Z)" "$2"' _ "$rc" "$t/out"
check "admin's guard, nightly timer and gateway are disabled and proven inactive, the gateway last, before the nightly" \
  in_order '^systemctl as=admin --user disable --now openclaw-listener-guard\.timer$' '^systemctl as=admin --user disable --now openclaw-gateway\.service$' \
  '^systemctl as=admin --user is-active openclaw-gateway\.service$' '^systemctl as=admin --user start openclaw-nightly-backup\.service$'
check "the nightly is taken with admin's gateway stopped, then copied, then imported" \
  in_order '^systemctl as=admin --user start openclaw-nightly-backup\.service$' \
  '^sudo -n cp -a .*/backups/claw-nightly-20261002T120000Z /home/sebastian/claw-import/claw-nightly-20261002T120000Z$' '^import final '
check "the import ran as the bot, from its home, with its user-session environment" \
  ev "^import final $B/claw-import/claw-nightly-20261002T120000Z \\| as=bot home=$B xdg=/run/user/2000 dbus=unix:path=/run/user/2000/bus pwd=$B "
check "  ... while admin's gateway was inactive" ev '^import final .* admin_gw=inactive '
check "the log dir the nightly recreated as admin is set aside after the nightly and before the import (R1)" \
  in_order '^systemctl as=admin --user start openclaw-nightly-backup\.service$' '^sudo -n mv .*/gwlog .*/gwlog\.pre-rehome-20261002T120000Z$' '^import final '
check "  ... so the dir the bot logs into holds no marker of admin's" \
  bash -c '[ ! -e "$1/.born-as-admin" ] && [ -f "$1.pre-rehome-20261002T120000Z/.born-as-admin" ]' _ "$t/gwlog"
check "admin's gateway logs were set aside before the import (Review Focus 1)" \
  bash -c 'grep -q "^import final .* gwlog=absent$" "$1" && [ -f "$2.pre-rehome-20261002T120000Z/openclaw-2026-10-01.log" ]' _ "$t/ev" "$t/gwlog"
check "the bot's copy is its own: a 700 dir, 600 files, handed to the bot" \
  bash -c '[ "$(ls -ld "$1" | cut -c1-10)" = drwx------ ] && [ -z "$(find "$1" -type f ! -perm 600)" ] && grep -q "^sudo -n chown -R sebastian:sebastian /home/sebastian/claw-import/claw-nightly-20261002T120000Z$" "$2"' \
  _ "$B/claw-import/claw-nightly-20261002T120000Z" "$t/ev"
check "admin's data is untouched by the switch" \
  bash -c '[ "$(cat "$1/.openclaw/credentials/whatsapp/default/creds.json")" = admin-creds ] && [ -d "$1/backups/claw-nightly-20261002T120000Z" ] && [ -f "$1/.wacli/session.db-shm" ]' _ "$A"
check "the switch is recorded" grep -qx 'final 20261002T120000Z claw-nightly-20261002T120000Z' "$t/varlib/claw-rehome/switched"
fresh; rh switch drill
check "switch drill imports as drill and points at a rehearsal verify" \
  bash -c '[ "$1" -eq 0 ] && grep -q "^import drill " "$2" && grep -q "rehome.sh verify rehearsal <lan-ip>" "$3"' _ "$rc" "$t/ev" "$t/out"
fresh; export FAKE_STUCK=admin:openclaw-gateway.service
refuses "an admin gateway that stays activating stops the switch" "admin's openclaw-gateway.service is 'activating'" switch final
check "  ... before the nightly and the import" bash -c '! grep -Eq "start openclaw-nightly-backup|^import " "$1"' _ "$t/ev"
fresh; export FAKE_NIGHTLY_FAIL=1
refuses "a nightly that fails stops the switch (Review Focus 2)" "the nightly backup failed" switch final
check "  ... before any import" bash -c '! grep -q "^import " "$1"' _ "$t/ev"
fresh; export FAKE_NIGHTLY_RESULT=exit-code
refuses "a nightly that ends without success stops the switch (Review Focus 2)" "did not end in success" switch final
fresh; export FAKE_NIGHT_TS=20261002T115959Z
refuses "a nightly older than the switch is never imported (Review Focus 2)" "refusing to import an older snapshot" switch final
check "  ... no copy, no import" bash -c '! grep -Eq "cp -a|^import " "$1"' _ "$t/ev"
fresh; export FAKE_IMPORT_RC=1
refuses "a failed import fails the switch and points at rollback" "import.sh final failed.*rollback" switch final
fresh; rh switch final; rh switch final
check "a second switch is refused (Review Focus 4)" bash -c '[ "$1" -eq 1 ] && [ "$(grep -c "^import " "$2")" -eq 1 ]' _ "$rc" "$t/ev"

# ===== verify =====
fresh; refuses "verify before any switch is refused (Review Focus 4)" "no switch is recorded" verify final 192.0.2.10
fresh; rh switch final; refuses "verify in the other mode is refused (Review Focus 4)" "verify it as 'final'" verify rehearsal 192.0.2.10
fresh; rh switch final; rh verify final 192.0.2.10
check "verify runs acceptance as the bot with the mode and the address, and records the pass" \
  bash -c '[ "$1" -eq 0 ] && grep -q "^acceptance final 192.0.2.10 | as=bot home=$3 xdg=/run/user/2000$" "$2" && [ -f "$4/claw-rehome/verified" ]' _ "$rc" "$t/ev" "$B" "$t/varlib"
fresh; rh switch final; export FAKE_ACC_RC=1; rh verify final 192.0.2.10
check "a failing acceptance fails verify and records no pass" \
  bash -c '[ "$1" -eq 1 ] && [ ! -e "$2/claw-rehome/verified" ] && grep -q "rollback" "$3"' _ "$rc" "$t/varlib" "$t/out"

# ===== retire =====
fresh; rh switch final; refuses "retire without a recorded pass is refused (Review Focus 4)" "no passing verify" retire
check "  ... and moved nothing" test -d "$A/.openclaw"
fresh; rh switch final; rh verify final 192.0.2.10; echo inactive > "$t/sd/bot/openclaw-gateway.service"
refuses "retire with the bot's gateway down is refused (Review Focus 4)" "not active" retire
fresh; rh switch final; rh verify final 192.0.2.10; rh retire
check "retire completes and names the deletion date" bash -c '[ "$1" -eq 0 ] && grep -q "delete it after 2026-10-16" "$2"' _ "$rc" "$t/out"
check "  ... the copy is root-only" evF "install -d -m 700 -o root -g root $R $R/home $R/units"
check "  ... admin's home holds no bot state any more" \
  bash -c 'for i in .openclaw brain .wacli ops backups .openclaw-stale-1 .ssh/ocsb_vault .ssh/config; do [ ! -e "$1/$i" ] || exit 1; done' _ "$A"
check "  ... admin keeps its own SSH login" grep -q AAAAlima "$A/.ssh/authorized_keys"
check "  ... everything is in the retired copy, units too" \
  bash -c '[ -f "$1/home/.openclaw/openclaw.json" ] && [ -d "$1/home/brain/vault" ] && [ -f "$1/home/.ssh/ocsb_vault" ] && [ -f "$1/units/openclaw-gateway.service" ] && [ ! -e "$2/.config/systemd/user/openclaw-gateway.service" ]' _ "$R" "$A"
check "  ... RETIRED lists them under a header with the deletion date" \
  bash -c 'head -1 "$1/RETIRED" | grep -q "delete after 2026-10-16" && grep -qx ".openclaw" "$1/RETIRED" && grep -qx ".ssh/ocsb_vault" "$1/RETIRED"' _ "$R"
check "  ... admin's linger is off" evF "loginctl disable-linger $(id -un)"
check "  ... and the bot's gateway was left running" test "$(st_of bot openclaw-gateway.service)" = active

# ===== rollback =====
fresh; rh switch final; rh verify final 192.0.2.10; rh rollback
check "rollback before retire completes; admin's gateway is active" \
  bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/admin/openclaw-gateway.service")" = active ]' _ "$rc" "$t/sd"
check "the bot's units were stopped and proven off before admin's gateway came back" \
  in_order '^systemctl as=bot --user disable --now openclaw-gateway\.service$' '^systemctl as=bot --user is-active openclaw-gateway\.service$' \
  '^systemctl as=admin --user enable --now openclaw-gateway\.service$'
check "the bot's WhatsApp state is carried to admin before admin's gateway starts (Review Focus 3)" \
  in_order '^sudo -n cp -a /home/sebastian/\.openclaw/credentials/whatsapp ' '^systemctl as=admin --user enable --now openclaw-gateway\.service$'
check "  ... admin now has the bot's credentials and session, and none of its old -shm" \
  bash -c '[ "$(cat "$1/.openclaw/credentials/whatsapp/default/creds.json")" = bot-creds ] && [ "$(cat "$1/.wacli/session.db")" = bot-session.db ] && [ -f "$1/.wacli/session.db-wal" ] && [ ! -e "$1/.wacli/session.db-shm" ]' _ "$A"
check "  ... admin's own set is kept aside, -shm included" \
  bash -c 'set -- "$1"/.claw-rollback-aside-*; [ "$#" -eq 1 ] && [ "$(cat "$1/.openclaw/credentials/whatsapp/default/creds.json")" = admin-creds ] && [ -f "$1/.wacli/session.db-shm" ]' _ "$A"
check "  ... the bot's copy and unit files are set aside in its home" \
  bash -c 'set -- "$1"/rehome-rolled-back-*; [ "$#" -eq 1 ] && [ -d "$1/.openclaw" ] && [ -f "$1/units/openclaw-gateway.service" ] && [ ! -e "$2/.openclaw" ] && [ ! -e "$2/.config/systemd/user/openclaw-gateway.service" ]' _ "$B" "$B"
check "  ... and the records are cleared" bash -c '[ ! -e "$1/switched" ] && [ ! -e "$1/verified" ]' _ "$t/varlib/claw-rehome"
fresh; rh switch final; rh rollback; TS=20261002T130000Z rh switch final
check "after a rollback the switch can run again" test "$rc" -eq 0
fresh; rh switch drill; rh rollback
check "a drill rollback carries nothing (the bot had no WhatsApp state) and leaves admin's set alone" \
  bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/.openclaw/credentials/whatsapp/default/creds.json")" = admin-creds ] && [ -f "$2/.wacli/session.db-shm" ] && ! ls -d "$2"/.claw-rollback-aside-* >/dev/null 2>&1' _ "$rc" "$A"
fresh; rh switch final; export FAKE_STUCK=bot:openclaw-gateway.service
refuses "a bot gateway that will not stop stops the rollback before admin's comes back" "bot's openclaw-gateway.service is 'activating'" rollback
check "  ... admin's gateway stays off" test "$(st_of admin openclaw-gateway.service)" = inactive
fresh; rh switch final; rh verify final 192.0.2.10; rh retire; TS=20261002T140000Z rh rollback
check "rollback after retire restores admin's copy from the retired dir, and removes that dir" \
  bash -c '[ "$1" -eq 0 ] && [ -f "$2/.openclaw/openclaw.json" ] && [ -d "$2/brain/vault" ] && [ -f "$2/.ssh/ocsb_vault" ] && [ -f "$2/.config/systemd/user/openclaw-gateway.service" ] && [ ! -e "$3" ]' _ "$rc" "$A" "$R"
check "  ... turns admin's linger back on and carries the bot's WhatsApp state" \
  bash -c 'grep -q "loginctl enable-linger" "$1" && [ "$(cat "$2/.openclaw/credentials/whatsapp/default/creds.json")" = bot-creds ]' _ "$t/ev" "$A"
check "  ... and admin's gateway is active" test "$(st_of admin openclaw-gateway.service)" = active
fresh; mkdir -p "$t/varlib/claw-retired-admin-20261001" "$t/varlib/claw-retired-admin-20261002"; rm -rf "$A/.openclaw"
refuses "two retired copies are left to the owner" "more than one retired copy" rollback
fresh; mkdir -p "$t/varlib/claw-retired-admin-20261002"
refuses "a retired dir with no RETIRED next to admin's own state is left to the owner, nothing stopped" "no readable .*RETIRED: nothing was stopped" rollback

# ===== rollback: preflight before anything stops (I1) and admin's gateway proven down before the WhatsApp swap (I2) =====
fresh; echo kh > "$A/.ssh/known_hosts"; rh switch final; rh verify final 192.0.2.10; rh retire
echo newkh > "$A/.ssh/known_hosts"; echo "[Unit]" > "$A/.config/systemd/user/openclaw-gateway.service"; : > "$t/ev"; TS=20261002T140000Z rh rollback
check "rollback after retire refuses, naming every collision (a recreated file and a recreated unit), before stopping anything" \
  bash -c '[ "$1" -eq 1 ] && grep -qF "$2/.ssh/known_hosts" "$3" && grep -qF "$2/.config/systemd/user/openclaw-gateway.service" "$3" && grep -q "nothing was stopped" "$3" && ! grep -q "^systemctl" "$4"' _ "$rc" "$A" "$t/out" "$t/ev"
check "  ... the bot's gateway keeps running, the retired copy stays whole, nothing of admin's was restored" \
  bash -c '[ "$(cat "$1/bot/openclaw-gateway.service")" = active ] && [ -f "$2/RETIRED" ] && [ -d "$2/home/.openclaw" ] && [ ! -e "$3/.openclaw" ]' _ "$t/sd" "$R" "$A"
rm "$A/.ssh/known_hosts" "$A/.config/systemd/user/openclaw-gateway.service"; TS=20261002T141000Z rh rollback
check "  ... with the collisions cleared, the same rollback goes through" \
  bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/.ssh/known_hosts")" = kh ] && [ "$(cat "$3/admin/openclaw-gateway.service")" = active ]' _ "$rc" "$A" "$t/sd"
fresh; echo kh > "$A/.ssh/known_hosts"; rh switch final; rh verify final 192.0.2.10; export FAKE_MV_FAIL=ocsb_vault; rh retire; unset FAKE_MV_FAIL
check "a retire that dies half-way leaves its exact list as RETIRING and no RETIRED" \
  bash -c '[ "$1" -eq 1 ] && [ -f "$2/RETIRING" ] && [ ! -e "$2/RETIRED" ] && grep -qx ".ssh/ocsb_vault" "$2/RETIRING" && grep -qx ".openclaw" "$2/RETIRING"' _ "$rc" "$R"
: > "$t/ev"; TS=20261002T140000Z rh rollback
check "rollback after that refuses for want of a RETIRED, before stopping the bot" \
  bash -c '[ "$1" -eq 1 ] && grep -q "no readable .*RETIRED" "$2" && grep -q "RETIRING" "$2" && ! grep -q "^systemctl" "$3" && [ "$(cat "$4/bot/openclaw-gateway.service")" = active ]' _ "$rc" "$t/out" "$t/ev" "$t/sd"
fresh; rh switch final; echo inactive > "$t/sd/bot/openclaw-gateway.service"; echo active > "$t/sd/admin/openclaw-gateway.service"; : > "$t/ev"; rh rollback
check "rollback stops admin's gateway, proven, before it swaps any WhatsApp file, and starts it again at the end" \
  in_order '^systemctl as=admin --user disable --now openclaw-gateway\.service$' '^systemctl as=admin --user is-active openclaw-gateway\.service$' \
  '^sudo -n cp -a /home/sebastian/\.openclaw/credentials/whatsapp ' '^systemctl as=admin --user enable --now openclaw-gateway\.service$'
check "  ... and the swap happened" \
  bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/.openclaw/credentials/whatsapp/default/creds.json")" = bot-creds ] && [ "$(cat "$3/admin/openclaw-gateway.service")" = active ]' _ "$rc" "$A" "$t/sd"

# ===== rollback: WhatsApp state by family (minor 1) =====
fresh; rh switch final; rm -f "$B/.wacli/"session.db*; rh rollback
check "a bot with credentials but no wacli session: its credentials are carried, admin's wacli session stays put" \
  bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/.openclaw/credentials/whatsapp/default/creds.json")" = bot-creds ] && [ "$(cat "$2/.wacli/session.db")" = admin-session.db ] && [ -f "$2/.wacli/session.db-shm" ]' _ "$rc" "$A"
check "  ... and only the credentials family went aside" \
  bash -c 'set -- "$1"/.claw-rollback-aside-*; [ "$#" -eq 1 ] && [ -f "$1/.openclaw/credentials/whatsapp/default/creds.json" ] && [ ! -e "$1/.wacli" ]' _ "$A"

# ===== retire: a second one is refused (minor 2) =====
fresh; rh switch final; rh verify final 192.0.2.10; rh retire; echo x > "$A/.ssh/known_hosts"; : > "$t/ev"; DAY=20261003 rh retire
check "a second retire (a later day, a new ~/.ssh file) is refused and moves nothing" \
  bash -c '[ "$1" -eq 1 ] && grep -q "retire already ran: " "$2" && [ -f "$3/.ssh/known_hosts" ] && [ ! -e "$4/claw-retired-admin-20261003" ] && ! grep -q "^systemctl" "$5"' _ "$rc" "$t/out" "$A" "$t/varlib" "$t/ev"

# ===== verify: usage pass-through (minor 6), import record (minor 8); the nightly service (minor 9); next-step text (minor 7); R =====
fresh; rh switch final; export FAKE_ACC_RC=2; rh verify final not-an-address
check "an acceptance usage error (exit 2) makes verify exit 2 as a usage error, with no FAILED/rollback advice and no pass recorded" \
  bash -c '[ "$1" -eq 2 ] && grep -q "usage error" "$2" && ! grep -Eq "FAILED|rollback" "$2" && [ ! -e "$3/claw-rehome/verified" ]' _ "$rc" "$t/out" "$t/varlib"
fresh; export FAKE_IMPORT_RC=1; rh switch final; unset FAKE_IMPORT_RC; refuses "verify after a failed import is refused: no successful import is recorded" "no successful import" verify final 192.0.2.10
check "  ... acceptance never ran" bash -c '! grep -q "^acceptance " "$1"' _ "$t/ev"
fresh; export FAKE_IMPORT_RC=1; rh switch final; unset FAKE_IMPORT_RC; TS=20261002T130000Z rh rollback
check "  ... and rollback still works after a failed import" bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/admin/openclaw-gateway.service")" = active ]' _ "$rc" "$t/sd"
fresh; rh switch final
check "a successful import is recorded" test -f "$t/varlib/claw-rehome/imported"
fresh; rh switch final; rh verify final 192.0.2.10; rh rollback
check "rollback clears the import record" test ! -e "$t/varlib/claw-rehome/imported"
fresh; rh switch final
check "switch stops admin's nightly service as well as its timer, proven" \
  bash -c 'grep -q "^systemctl as=admin --user disable --now openclaw-nightly-backup\.service$" "$1" && grep -q "^systemctl as=admin --user is-active openclaw-nightly-backup\.service$" "$1"' _ "$t/ev"
fresh; rh switch final; export FAKE_STUCK=bot:openclaw-nightly-backup.service
refuses "a bot nightly service that will not stop stops the rollback" "bot's openclaw-nightly-backup.service is 'activating'" rollback
fresh; export FAKE_STUCK=admin:openclaw-gateway.service
refuses "an admin stop refusal during switch says nothing was imported and points at rollback" "nothing was imported; run rehome.sh rollback" switch final
fresh; export FAKE_MV_FAIL=gwlog; rh switch final
check "a raw set -e failure names the phase, a line and the records (the count admin's gateway listed), and still fails" \
  bash -c '[ "$1" -eq 1 ] && grep -Eq "^rehome: rehome.sh switch failed \(line [0-9]+\); records: cron-total ; see README \"Move the bot to its own account\"" "$2"' _ "$rc" "$t/out"
fresh; refuses "a die does not also print the raw-failure line" "no switch is recorded" verify final 192.0.2.10
check "  ... (no 'failed (line')" bash -c '! grep -q "failed (line" "$1"' _ "$t/out"
fresh; rh switch final; rh verify final 192.0.2.10; export FAKE_MV_FAIL=ocsb_vault; rh retire; unset FAKE_MV_FAIL; TS=20261002T140000Z rh rollback
check "R: rollback refusing a half-done retire says the RETIRING items present under <dir>/home are the ones that moved, to restore by hand" \
  bash -c '[ "$1" -eq 1 ] && grep -qF "$2/RETIRING" "$3" && grep -qF "present under $2/home" "$3" && grep -q "by hand" "$3" && grep -q "nothing was stopped" "$3"' _ "$rc" "$R" "$t/out"

# ===== the state-path migration (addendum 2026-10-05): admin's automation count before the stop; verify checks it =====
fresh; rh switch final
check "switch reads admin's automation count as admin, before anything of admin's is stopped" \
  in_order '^openclaw as=admin cron list --all --json$' '^systemctl as=admin --user disable --now openclaw-listener-guard\.timer$'
check "  ... and records it" bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/claw-rehome/cron-total")" = 21 ] && grep -q "lists 21 automation" "$3"' _ "$rc" "$t/varlib" "$t/out"
for bad in rc '{}' 'not json' '{"total":"21"}' '{"total":-1}'; do
  fresh
  if [ "$bad" = rc ]; then export FAKE_CRON_RC=1; else export FAKE_CRON_JSON="$bad"; fi
  refuses "an automation count that cannot be read ($bad) stops the switch" "cannot read admin's automation count .*nothing was stopped" switch final
  check "  ... before admin's units are touched, the nightly or the import ($bad)" \
    bash -c '! grep -Eq "disable --now|start openclaw-nightly-backup|^import " "$1" && [ "$(cat "$2/admin/openclaw-gateway.service")" = active ] && [ ! -e "$3/claw-rehome/switched" ]' _ "$t/ev" "$t/sd" "$t/varlib"
done
fresh; rh switch final; rh verify final 192.0.2.10
check "verify runs the state-path check as the bot, with the recorded count, after acceptance passed" \
  bash -c '[ "$1" -eq 0 ] && [ -f "$2/claw-rehome/verified" ]' _ "$rc" "$t/varlib"
check "  ... in that order" in_order '^acceptance final ' "^python3 as=bot $t/repo/migrate/state-paths\\.py check --home $B --cron-total 21\$"
fresh; rh switch final; export FAKE_CHECK_RC=1; rh verify final 192.0.2.10
check "a failing state-path check fails verify, records no pass and gives the fix-forward-or-rollback advice" \
  bash -c '[ "$1" -eq 1 ] && [ ! -e "$2/claw-rehome/verified" ] && grep -q "state-path check FAILED (see above): fix forward, or rehome.sh rollback" "$3"' _ "$rc" "$t/varlib" "$t/out"
fresh; rh switch final; export FAKE_ACC_RC=1; rh verify final 192.0.2.10
check "a failing acceptance does not go on to the state-path check" bash -c '[ "$1" -eq 1 ] && ! grep -q "^python3 .*state-paths\.py check " "$2"' _ "$rc" "$t/ev"
check "  ... nor to the bot gateway's automation count" bash -c '! grep -q "^openclaw as=bot " "$1"' _ "$t/ev"
# Fix round 1, I1: the gateway's own view (§8.5 item 1), not only the rows the migration wrote.
fresh; rh switch final; : > "$t/ev"; rh verify final 192.0.2.10
check "verify reads the bot gateway's automation count, as the bot, after acceptance passed" \
  bash -c '[ "$1" -eq 0 ] && grep -q "the bot.s gateway lists 21 automation(s), as admin.s did" "$2"' _ "$rc" "$t/out"
check "  ... in that order" in_order '^acceptance final ' '^openclaw as=bot cron list --all --json$'
fresh; rh switch final; export FAKE_BOT_CRON_JSON='{"total":24,"jobs":[]}'; rh verify final 192.0.2.10
check "a bot gateway listing another count than admin's fails verify, records no pass, with the advice" \
  bash -c '[ "$1" -eq 1 ] && [ ! -e "$2/claw-rehome/verified" ] && grep -q "the bot.s gateway lists 24 automation(s), admin.s listed 21: fix forward, or rehome.sh rollback" "$3"' _ "$rc" "$t/varlib" "$t/out"
check "  ... and the state-path check still ran, for its reasons" evF "python3 as=bot $t/repo/migrate/state-paths.py check --home $B --cron-total 21"
for bad in rc '{}' 'not json'; do
  fresh; rh switch final
  if [ "$bad" = rc ]; then export FAKE_BOT_CRON_RC=1; else export FAKE_BOT_CRON_JSON="$bad"; fi
  rh verify final 192.0.2.10
  check "a bot automation count that cannot be read ($bad) fails verify and records no pass" \
    bash -c '[ "$1" -eq 1 ] && [ ! -e "$2/claw-rehome/verified" ] && grep -q "cannot read the bot.s automation count" "$3"' _ "$rc" "$t/varlib" "$t/out"
done
# Fix round 2, item 3: a gateway that is still starting answers null/nothing for a while; that is retried (bounded),
# a numeric mismatch is not.
calls() { grep -c "^openclaw as=$1 cron list --all --json\$" "$t/ev" || true; }
fresh; rh switch final; export FAKE_BOT_CRON_NULLS=3; : > "$t/ev"; rh verify final 192.0.2.10
check "a bot count that is null at first and then equals admin's passes verify, after 4 reads" \
  bash -c '[ "$1" -eq 0 ] && [ -f "$2/claw-rehome/verified" ] && [ "$3" -eq 4 ]' _ "$rc" "$t/varlib" "$(calls bot)"
fresh; rh switch final; export FAKE_BOT_CRON_NULLS=999; : > "$t/ev"; rh verify final 192.0.2.10
check "a bot count that stays unreadable fails verify after 1 + 12 reads, with the hint to run verify again" \
  bash -c '[ "$1" -eq 1 ] && [ ! -e "$2/claw-rehome/verified" ] && [ "$3" -eq 13 ] && grep -q "cannot read the bot.s automation count .*; the gateway may still be starting: run rehome.sh verify again" "$4"' _ "$rc" "$t/varlib" "$(calls bot)" "$t/out"
fresh; rh switch final; export FAKE_BOT_CRON_JSON='{"total":20,"jobs":[]}'; : > "$t/ev"; rh verify final 192.0.2.10
check "a numeric mismatch fails at once: one read, no retry" bash -c '[ "$1" -eq 1 ] && [ "$2" -eq 1 ]' _ "$rc" "$(calls bot)"
fresh; export FAKE_CRON_NULLS=2; : > "$t/ev"; rh switch final
check "switch's admin count that is null at first and then numeric is recorded, after 3 reads" \
  bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/claw-rehome/cron-total")" = 21 ] && [ "$3" -eq 3 ]' _ "$rc" "$t/varlib" "$(calls admin)"
fresh; export FAKE_CRON_NULLS=999; : > "$t/ev"
refuses "an admin count that stays unreadable stops the switch before the stop" "cannot read admin's automation count .*nothing was stopped" switch final
check "  ... after 1 + 12 reads, before anything of admin's is stopped" \
  bash -c '[ "$1" -eq 13 ] && ! grep -Eq "disable --now|^import " "$2"' _ "$(calls admin)" "$t/ev"
fresh; rh switch final; export FAKE_BOT_CRON_JSON='{"total":20,"jobs":[]}' FAKE_CHECK_RC=1; rh verify final 192.0.2.10
check "both failing: verify names both" \
  bash -c '[ "$1" -eq 1 ] && grep -q "lists 20 automation(s), admin.s listed 21; the state-path check FAILED (see above): fix forward" "$2"' _ "$rc" "$t/out"
fresh; rh switch final; rm "$t/varlib/claw-rehome/cron-total"; : > "$t/ev"
refuses "verify without a recorded automation count is refused" "no automation count is recorded for this switch" verify final 192.0.2.10
check "  ... before acceptance runs" bash -c '! grep -q "^acceptance " "$1"' _ "$t/ev"
fresh; rh switch final; rh rollback
check "rollback clears the recorded count" test ! -e "$t/varlib/claw-rehome/cron-total"

# ===== the lock =====
fresh; rh prepare
check "a phase takes the lock (flock -n 9) before it touches any unit" \
  bash -c 'grep -q "^flock -n 9$" "$1" && [ "$(grep -n "^flock" "$1" | head -1 | cut -d: -f1)" -lt "$(grep -n "^systemctl\|^loginctl" "$1" | head -1 | cut -d: -f1)" ]' _ "$t/ev"
fresh; export FAKE_LOCK_HELD=1
refuses "a second phase while one holds the lock is refused" "another rehome.sh is running \(lock $t/lock\)" switch final
check "  ... with no unit stopped or started and nothing recorded" \
  bash -c '! grep -q "^systemctl" "$1" && [ ! -e "$2/claw-rehome" ]' _ "$t/ev" "$t/varlib"
fresh; export FAKE_LOCK_HELD=1
refuses "rollback is refused too while the lock is held" "another rehome.sh is running" rollback
check "  ... touching no unit" bash -c '! grep -q "^systemctl" "$1"' _ "$t/ev"
fresh; LOCKP="$t/nodir/sub/lock" rh prepare
check "an unopenable lock file stops the phase (no lock, no phase)" bash -c '[ "$1" -eq 1 ] && ! grep -q "^systemctl" "$2"' _ "$rc" "$t/ev"
fresh; rh switch; check "usage errors take no lock" bash -c '[ "$1" -eq 2 ] && ! grep -q "^flock" "$2"' _ "$rc" "$t/ev"
fresh; rh switch final; export FAKE_BOT_REVIVE=1
refuses "rollback dies if the bot's gateway came back before admin's units are enabled" "bot's openclaw-gateway.service is 'active' before admin's units" rollback
check "  ... and enables none of admin's units" test "$(grep -c '^systemctl as=admin --user enable' "$t/ev")" -eq 0

# ===== fix round 2 =====
# item 2: a brain dir the scan cannot enter is fatal, not "a file changed" (probe I1)
fresh; echo "leftover $A/bin" > "$A/brain/n.txt"; chmod 600 "$A/brain"; rh prepare; chmod 700 "$A/brain"
check "I1: an unreadable brain dir makes prepare refuse, with no harmless line and no OK" \
  bash -c '[ "$1" -eq 1 ] && grep -qF "cannot copy $2/brain for the leftover scan" "$3" && ! grep -q "harmless" "$3" && ! grep -q "^prepare: OK" "$3"' _ "$rc" "$A" "$t/out"
check "  ... scratch gone" scratch_gone
# item 6: only usage() owns exit 2; any other command that exits 2 inside a phase still gets the raw-failure line
fresh; export FAKE_MV_FAIL=gwlog FAKE_MV_RC=2; rh switch final
check "item 6: an unhandled command exiting 2 inside a phase prints the failed (line N) line" \
  bash -c '[ "$1" -eq 2 ] && grep -Eq "^rehome: rehome.sh switch failed \(line [0-9]+\)" "$2"' _ "$rc" "$t/out"
fresh; rh bogus
check "item 6: a usage error with an unknown phase prints no failed (line N) line" bash -c '[ "$1" -eq 2 ] && ! grep -q "failed (line" "$2"' _ "$rc" "$t/out"
fresh; rh switch
check "item 6: a usage error inside a known phase prints no failed (line N) line" bash -c '[ "$1" -eq 2 ] && ! grep -q "failed (line" "$2"' _ "$rc" "$t/out"
# item 3: the lock on verify and retire, and the preflight's "missing from the retired copy" branch
fresh; rh switch final; export FAKE_LOCK_HELD=1; : > "$t/ev"
refuses "item 3: verify is refused while the lock is held" "another rehome.sh is running" verify final 192.0.2.10
check "  ... acceptance never ran" bash -c '! grep -q "^acceptance " "$1"' _ "$t/ev"
fresh; rh switch final; rh verify final 192.0.2.10; export FAKE_LOCK_HELD=1; : > "$t/ev"
refuses "item 3: retire is refused while the lock is held" "another rehome.sh is running" retire
check "  ... nothing was stopped or moved" bash -c '! grep -q "^systemctl" "$1" && [ -d "$2/.openclaw" ]' _ "$t/ev" "$A"
fresh; rh switch final; rh verify final 192.0.2.10; rh retire; rm -rf "$R/home/.ssh/ocsb_vault"; : > "$t/ev"; TS=20261002T140000Z rh rollback
check "item 3: a listed item missing from the retired copy is named, and rollback stops nothing" \
  bash -c '[ "$1" -eq 1 ] && grep -qF "$2/home/.ssh/ocsb_vault (missing from the retired copy)" "$3" && ! grep -q "^systemctl" "$4"' _ "$rc" "$R" "$t/out" "$t/ev"
# item 5 (probe F): a relative symlink that dangles once moved is not "missing"
fresh; ln -s ../../admin/ops "$A/.ssh/lnk"; rh switch final; rh verify final 192.0.2.10; rh retire; TS=20261002T140000Z rh rollback
check "item 5: a relative symlink dangling in the retired copy is restored by rollback" \
  bash -c '[ "$1" -eq 0 ] && [ -L "$2/.ssh/lnk" ] && [ ! -e "$3" ]' _ "$rc" "$A" "$R"
# item 4 (probes A', E4): a RETIRING state gets the R message first, and collisions are named together
fresh; rh switch final; rh verify final 192.0.2.10; export FAKE_MV_FAIL=.openclaw; rh retire; unset FAKE_MV_FAIL; : > "$t/ev"; TS=20261002T140000Z rh rollback
check "E4: a retire that died on its first move (admin's .openclaw still there) gets the RETIRING explanation, not 'decide by hand'" \
  bash -c '[ "$1" -eq 1 ] && grep -qF "$2/RETIRING" "$3" && grep -qF "present under $2/home" "$3" && ! grep -q "decide by hand" "$3" && ! grep -q "^systemctl" "$4"' _ "$rc" "$R" "$t/out" "$t/ev"
fresh; rh switch final; rh verify final 192.0.2.10; rh retire; mkdir -p "$A/.openclaw"; echo x > "$A/.ssh/ocsb_vault"; : > "$t/ev"; TS=20261002T140000Z rh rollback
check "A': both ~/.openclaw and the retired copy exist: every collision is named together, nothing stopped" \
  bash -c '[ "$1" -eq 1 ] && grep -qF "$2/.openclaw (exists in admin" "$3" && grep -qF "$2/.ssh/ocsb_vault (exists in admin" "$3" && ! grep -q "^systemctl" "$4"' _ "$rc" "$A" "$t/out" "$t/ev"
# item 1 (probes E3, G2): the R message's hand-restore, followed exactly, lets rollback go through; linger always comes back
fresh; rh switch final; rh verify final 192.0.2.10; export FAKE_MV_FAIL=ocsb_vault; rh retire; unset FAKE_MV_FAIL; TS=20261002T140000Z rh rollback
check "item 1: the R message names the exact command to move the emptied retired dir aside" \
  bash -c 'grep -qF "sudo mv $1 $1.restored-by-hand" "$2"' _ "$R" "$t/out"
# by hand, as the message says: the items that moved go back, then the dir moves aside
for it in .openclaw brain .wacli ops backups .openclaw-stale-1; do [ ! -e "$R/home/$it" ] || mv "$R/home/$it" "$A/$it"; done
mv "$R/units/"* "$A/.config/systemd/user/" 2>/dev/null || true
mv "$R" "$R.restored-by-hand"; : > "$t/ev"; TS=20261002T150000Z rh rollback
check "item 1: after the hand restore, the re-run rollback goes through (the .restored-by-hand dir is ignored) and admin's gateway is active" \
  bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2/admin/openclaw-gateway.service")" = active ] && [ -d "$3.restored-by-hand" ]' _ "$rc" "$t/sd" "$R"
check "  ... and admin's linger was turned back on (no retired copy involved)" evF "loginctl enable-linger $(id -un)"
fresh; rh switch final; rh rollback
check "item 1: a plain rollback before any retire also turns admin's linger on" evF "loginctl enable-linger $(id -un)"

echo "rehome tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
