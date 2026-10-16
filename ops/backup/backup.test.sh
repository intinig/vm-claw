#!/bin/bash
# Tests for the guest nightly backup (ops/backup/nightly-backup.sh) and the host pull + restic job
# (host/pull-backups.sh). Everything runs in scratch directories with fake openclaw, limactl, restic,
# security, df, date, tar and mv first on PATH: never the real ~/Backups, iCloud Drive or keychain.
# Part 1: the nightly. Part 2: the host pull. Part 3: the units and the launchd plist.
# The bash -c snippets below are single-quoted on purpose: they expand inside the child shell.
# shellcheck disable=SC2016,SC2012  # ls is fine for the simple names used here
set -euo pipefail
umask 022   # the mode assertions below must not depend on the caller's umask
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
nightly="$here/nightly-backup.sh"
pull="$repo/host/pull-backups.sh"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
pass=0; fail=0
expect() { # expect <exit-code> <description> <cmd...>
  local want="$1" desc="$2"; shift 2
  set +e; "$@" >"$t/out" 2>&1; local got=$?; set -e
  if [ "$got" -eq "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $desc (exit $got, want $want)"; cat "$t/out"; fi
}
expect_msg() { # expect_msg <exit-code> <output-regex> <description> <cmd...>: exit code AND message
  local want="$1" pat="$2" desc="$3"; shift 3
  set +e; "$@" >"$t/out" 2>&1; local got=$?; set -e
  if [ "$got" -eq "$want" ] && grep -Eq -- "$pat" "$t/out"; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $desc (exit $got, want $want, output must match: $pat)"; cat "$t/out"; fi
}
check() { # check <description> <cmd...>: the command must succeed
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1))
  else fail=$((fail+1)); echo "FAIL: $desc"; fi
}
sum256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
mib() { head -c $((1048576 * $1)) /dev/zero > "$2"; } # mib <n> <file>
stamp() { printf '202001%02dT000000' "$1"; }          # stamp <n>: the n-th day of a fixture month, newest = highest n
mode_of() { { ls -ld "$1" 2>/dev/null || true; } | cut -c1-10; }

# ===== fakes =======================================================================================
mkdir -p "$t/bin" "$t/hbin"
cat > "$t/bin/openclaw" <<'EOF'
#!/bin/bash
# Fake `openclaw backup create --output DIR --verify`: writes FAKE_ARCHIVES (default 1) archives named like
# the real ones, then optionally fails. Logs the output dir so the test can see where the run wrote.
echo "openclaw $*" >> "$FAKE_LOG"
[ "$1 $2" = "backup create" ] || exit 0
out=""; while [ $# -gt 0 ]; do if [ "$1" = --output ]; then out="$2"; fi; shift; done
echo "outdir=$out" >> "$FAKE_LOG"
echo "lock=$([ -d "$HOME/backups/.lock" ] && echo held || echo free)" >> "$FAKE_LOG"
echo "lockpid=$(cat "$HOME/backups/.lock/pid" 2>/dev/null)" >> "$FAKE_LOG"
tmp=$(mktemp -d); mkdir -p "$tmp/.openclaw"; echo '{}' > "$tmp/.openclaw/openclaw.json"
i=0; while [ "$i" -lt "${FAKE_ARCHIVES:-1}" ]; do
  /usr/bin/tar -C "$tmp" -czf "$out/2026-01-01T00-00-0$i.000Z-openclaw-backup.tar.gz" .openclaw; i=$((i+1))
done
rm -rf "$tmp"
[ -z "${FAKE_OPENCLAW_FAIL:-}" ] || { echo "openclaw: simulated failure" >&2; exit 1; }
exit 0
EOF
cat > "$t/bin/df" <<'EOF'
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 1000000000 1 ${FAKE_DF_AVAIL_KB:-100000000} 1% /"
EOF
cat > "$t/bin/date" <<'EOF'
#!/bin/bash
if [ -n "${FAKE_DATE:-}" ] && [ "${2:-}" = "+%Y%m%dT%H%M%SZ" ]; then echo "$FAKE_DATE"; exit 0; fi
exec /bin/date "$@"
EOF
cat > "$t/bin/mv" <<'EOF'
#!/bin/bash
# Real mv; logs the rename that publishes a finished backup, and whether its MANIFEST existed at that moment.
src=""; dest=""; for a in "$@"; do src="$dest"; dest="$a"; done
case "$dest" in
  */claw-nightly-*Z)
    case "$src" in *.partial) p=yes ;; *) p=no ;; esac
    echo "publish from_partial=$p manifest=$([ -f "$src/MANIFEST" ] && echo yes || echo no)" >> "$FAKE_LOG" ;;
esac
exec /bin/mv "$@"
EOF
cat > "$t/bin/tar" <<'EOF'
#!/bin/bash
# Fake tar: the real one, plus a scripted exit status and message for the filestate archive (FAKE_TAR_RC).
/usr/bin/tar "$@"; rc=$?
if [ -n "${FAKE_TAR_RC:-}" ] && [[ " $* " == *" -czf "* ]]; then echo "tar: ${FAKE_TAR_MSG:-simulated}" >&2; exit "$FAKE_TAR_RC"; fi
exit $rc
EOF
cat > "$t/hbin/limactl" <<'EOF'
#!/bin/bash
# Fake limactl over a local directory standing in for the bot's home in the guest ($FAKE_GUEST). A `shell` call must
# be `shell --workdir / <instance> -- sudo -n -u sebastian -- <cmd...>` (only the bot can read its backups); <cmd>
# then runs here, with /home/sebastian mapped onto $FAKE_GUEST.
echo "limactl $*" >> "$FAKE_LOG"
[ "$1" = shell ] || exit 0
[ -z "${FAKE_LIMA_DOWN:-}" ] || { echo "limactl: instance is not running" >&2; exit 1; }
shift
if [ "$1" != --workdir ] || [ "$2" != / ]; then echo "fake limactl: expected --workdir /" >&2; exit 97; fi
shift 3   # --workdir / <instance>
if [ "$1 $2 $3 $4 $5 $6" != "-- sudo -n -u sebastian --" ]; then echo "fake limactl: not run as the bot through sudo: $*" >&2; exit 98; fi
shift 6
if [ -n "${FAKE_STAMP_FAIL:-}" ] && [[ "$*" == *host-pull-ok* ]]; then echo "limactl: simulated stamp write failure" >&2; exit 1; fi
args=(); for a in "$@"; do args+=("${a//\/home\/sebastian/$FAKE_GUEST}"); done
if [ "${args[0]}" = tar ]; then
  echo "lockpid=$(cat "${CLAW_BACKUP_DEST:-$HOME/Backups/vm-claw}/.lock/pid" 2>/dev/null)" >> "$FAKE_LOG"
  night="${args[${#args[@]}-1]}"
  if [ -n "${FAKE_COPY_VANISH:-}" ] && [ "$night" = "$FAKE_COPY_VANISH" ]; then
    # the guest prunes this night while it is streamed: part of it arrives, then the source is gone
    tar -C "$FAKE_GUEST/backups" -cf - "$night" | head -c 600
    rm -rf "$FAKE_GUEST/backups/$night"
    echo "tar: $night: Cannot stat: No such file or directory" >&2; exit 2
  fi
fi
HOME="$FAKE_GUEST" "${args[@]}"; rc=$?
if [ "${args[0]}" = tar ] && [ -n "${FAKE_COPY_FAIL:-}" ]; then echo "limactl: simulated connection loss" >&2; exit 255; fi
exit "$rc"
EOF
cat > "$t/hbin/date" <<'EOF'
#!/bin/bash
# The host's clock, when a test sets FAKE_NOW (epoch seconds); everything else is the real date.
if [ -n "${FAKE_NOW:-}" ] && [ "$*" = "-u +%s" ]; then echo "$FAKE_NOW"; exit 0; fi
exec /bin/date "$@"
EOF
cat > "$t/hbin/restic" <<'EOF'
#!/bin/bash
# Fake restic: logs the call and the settings it would see. Like the real one it runs the password command
# when no password is set, and it needs an initialised repository (a config file) for backup and forget.
echo "restic $* | repo=${RESTIC_REPOSITORY-<unset>} pw=${RESTIC_PASSWORD:+set} pwcmd=${RESTIC_PASSWORD_COMMAND-<unset>}" >> "$FAKE_LOG"
if [ -z "${RESTIC_PASSWORD:-}" ] && [ -n "${RESTIC_PASSWORD_COMMAND:-}" ]; then sh -c "$RESTIC_PASSWORD_COMMAND" >/dev/null || exit 1; fi
case "$1" in
  init) mkdir -p "$RESTIC_REPOSITORY"; echo cfg > "$RESTIC_REPOSITORY/config"; : > "$RESTIC_REPOSITORY/snaps" ;;
  snapshots) [ -z "${FAKE_SNAPSHOTS_FAIL:-}" ] || { echo "Fatal: unable to open config file" >&2; exit 1; }
    [ -e "$RESTIC_REPOSITORY/config" ] || { echo "Fatal: repository does not exist" >&2; exit 1; }
    # the repository's snapshots as restic prints them with --json: one path each, plus the tag
    printf '['; sep=""
    while IFS= read -r p; do [ -n "$p" ] || continue; printf '%s{"time":"2020-01-01T00:00:00Z","paths":["%s"],"hostname":"h","tags":["vm-claw"]}' "$sep" "$p"; sep=","; done < "$RESTIC_REPOSITORY/snaps" 2>/dev/null
    echo ']' ;;
  backup|forget) [ -e "$RESTIC_REPOSITORY/config" ] || { echo "Fatal: repository does not exist" >&2; exit 1; }
    [ "${FAKE_RESTIC_FAIL:-}" != "$1" ] || { echo "Fatal: simulated restic $1 failure" >&2; exit 1; }
    if [ "$1" = backup ]; then for last; do :; done; echo "$last" >> "$RESTIC_REPOSITORY/snaps"; fi ;;
esac
exit 0
EOF
cat > "$t/hbin/security" <<'EOF'
#!/bin/bash
# Fake keychain: the real one is never reached.
echo "security $*" >> "$FAKE_LOG"
echo fake-restic-password
EOF
chmod +x "$t/bin/"* "$t/hbin/"*
reset_fakes() { unset FAKE_COPY_VANISH FAKE_NOW FAKE_TAR_RC FAKE_TAR_MSG FAKE_ARCHIVES FAKE_OPENCLAW_FAIL FAKE_DF_AVAIL_KB FAKE_DATE FAKE_COPY_FAIL FAKE_SNAPSHOTS_FAIL FAKE_LIMA_DOWN FAKE_STAMP_FAIL FAKE_RESTIC_FAIL || true; }

# ===== Part 1: the guest nightly ====================================================================
gh="$t/guest"
mkguest() { # a guest home with live state, a bootstrap .env that carries a shell-metacharacter line, no backups yet
  reset_fakes
  rm -rf "$gh" "$t/ev" "$t/sourced"; : > "$t/ev"
  mkdir -p "$gh/.openclaw/service-env" "$gh/brain/app/node_modules/pkg" "$gh/.wacli" "$gh/.ssh" "$gh/ops"
  printf '%s\n' 'OP_SERVICE_ACCOUNT_TOKEN=fixture_token' "touch \"$t/sourced\"" > "$gh/.openclaw/.env"
  echo 'export OP_SERVICE_ACCOUNT_TOKEN=macos_only' > "$gh/.openclaw/service-env/ai.openclaw.gateway.env"
  echo '{}' > "$gh/.openclaw/openclaw.json"
  echo a > "$gh/brain/app/a.txt"; echo b > "$gh/brain/app/node_modules/pkg/b.js"
  echo s > "$gh/.wacli/session.db"; echo k > "$gh/.ssh/authorized_keys"; echo o > "$gh/ops/x.sh"
}
mkdone() { # mkdone <n> [filler MiB]: a complete nightly dir for day n
  local d; d="$gh/backups/claw-nightly-$(stamp "$1")Z"
  mkdir -p "$d"; chmod 700 "$d"; echo a > "$d/openclaw-backup.tar.gz"; echo f > "$d/filestate.tar.gz"
  if [ -n "${2:-}" ]; then mib "$2" "$d/filler"; fi
}
mkpartial() { # mkpartial <stamp> [filler MiB]: a stale .partial left by a killed run
  local d="$gh/backups/claw-nightly-$1.partial"
  mkdir -p "$d"; chmod 700 "$d"; echo a > "$d/openclaw-backup.tar.gz"
  if [ -n "${2:-}" ]; then mib "$2" "$d/filler"; fi
}
# From / on purpose: anything relative to the working directory instead of $HOME would be missed.
run_nightly_at() { (cd / && env HOME="$gh" FAKE_LOG="$t/ev" PATH="$t/bin:$PATH" bash "$1"); }
run_nightly() { run_nightly_at "$nightly"; }
done_names() { { cd "$gh/backups" 2>/dev/null && ls -d claw-nightly-*Z 2>/dev/null; } | tr '\n' ' ' || true; }
partial_names() { { cd "$gh/backups" 2>/dev/null && ls -d claw-nightly-*.partial 2>/dev/null; } | tr '\n' ' ' || true; }
newest_dir() { { cd "$gh/backups" 2>/dev/null && ls -d claw-nightly-*Z 2>/dev/null | tail -1; } || true; }
ev() { grep -Eq -- "$1" "$t/ev"; }
names_of() { local n out=""; for n in "$@"; do out="$out""claw-nightly-$(stamp "$n")Z "; done; printf '%s' "$out"; }

# --- a normal run ---
mkguest
expect 0 "a nightly run completes" run_nightly
d="$gh/backups/$(newest_dir)"
check "exactly one complete nightly dir and no .partial" bash -c '[ "$(ls -d "$1"/claw-nightly-* | wc -l | tr -d " ")" = 1 ] && [ -z "$(ls -d "$1"/*.partial 2>/dev/null)" ]' _ "$gh/backups"
check "it holds exactly the export layout: MANIFEST, filestate.tar.gz, openclaw-backup.tar.gz" \
  bash -c '[ "$(ls "$1" | LC_ALL=C sort | tr "\n" " ")" = "MANIFEST filestate.tar.gz openclaw-backup.tar.gz " ]' _ "$d"
check "the MANIFEST starts with mode=nightly" bash -c '[ "$(head -1 "$1/MANIFEST")" = mode=nightly ]' _ "$d"
check "the MANIFEST verifies, strictly" bash -c 'cd "$1" && grep -v "^mode=" MANIFEST | sha256sum --strict -c -' _ "$d"
check "the MANIFEST lists both archives with 64-hex hashes" \
  bash -c 'cd "$1" && for f in openclaw-backup.tar.gz filestate.tar.gz; do awk -v f="$f" '"'"'$2 == f && $1 ~ /^[0-9a-f]{64}$/ { ok = 1 } END { exit !ok }'"'"' MANIFEST || exit 1; done' _ "$d"
check "the dir is mode 700, its files 600, the backups root 700" \
  bash -c '[ "$(ls -ld "$1" | cut -c1-10)" = drwx------ ] && [ "$(ls -ld "$2" | cut -c1-10)" = drwx------ ] && [ -z "$(ls -l "$1" | sed 1d | cut -c1-10 | grep -v -x -e "-rw-------")" ]' _ "$d" "$gh/backups"
check "the OpenClaw backup is verified and written to a .partial dir, not to the final name" ev '^openclaw backup create --output .*/claw-nightly-[0-9TZ]+\.partial --verify$'
check "the .partial is renamed to the final name only after the MANIFEST exists" ev '^publish from_partial=yes manifest=yes$'
check "import.sh's validation accepts the nightly (as a drill)" env IMPORT_DRY=1 IMPORT_HOME="$t/ihome" bash "$repo/migrate/import.sh" drill "$d"
check "filestate carries the state files, the .env and the ssh keys" \
  bash -c 'l=$(tar -tzf "$1/filestate.tar.gz"); for m in brain/app/a.txt .wacli/session.db .ssh/authorized_keys ops/x.sh .openclaw/.env; do grep -q "^$m$" <<<"$l" || exit 1; done' _ "$d"
check "filestate leaves out brain node_modules and the macOS service-env dir" \
  bash -c '! tar -tzf "$1/filestate.tar.gz" | grep -Eq "node_modules|service-env"' _ "$d"
check "the .env was not sourced (a dotenv is data; the CLI loads it itself)" test ! -e "$t/sourced"
check "the lock was held while openclaw ran and is released afterwards" bash -c 'grep -q "^lock=held$" "$1" && [ ! -e "$2/backups/.lock" ]' _ "$t/ev" "$gh"
check "the lock records the pid of the running script (a later run can tell a dead holder from a live one)" ev '^lockpid=[0-9]+$'

# --- the .env is required ---
mkguest; rm "$gh/.openclaw/.env"
expect_msg 1 "\.openclaw/\.env is missing" "a missing ~/.openclaw/.env stops the run" run_nightly
check "a run without the .env wrote nothing and never called openclaw" bash -c '{ [ ! -d "$1/backups" ] || [ -z "$(ls -A "$1/backups")" ]; } && ! grep -q "^openclaw" "$2"' _ "$gh" "$t/ev"
mkguest; echo 'OTHER=1' > "$gh/.openclaw/.env"
expect_msg 1 "OP_SERVICE_ACCOUNT_TOKEN" "a .env without the token line stops the run (the nightly could not be restored)" run_nightly

# --- what must exist, what may be absent ---
mkguest; rm -rf "$gh/.wacli"
expect_msg 0 "\.wacli is missing" "a home without .wacli still backs up, with a warning" run_nightly
check "tar was not even asked for the missing path (bsdtar exits 1 on a missing file, which the tar-rc-1 tolerance would hide)" bash -c '! grep -Eq "tar exited|Cannot stat|No such file" "$1"' _ "$t/out"
check "that backup has everything else and no .wacli" bash -c 'l=$(tar -tzf "$1/backups/$2/filestate.tar.gz"); grep -q "^brain/app/a.txt$" <<<"$l" && grep -q "^ops/x.sh$" <<<"$l" && grep -q "^.openclaw/.env$" <<<"$l" && ! grep -q "^\.wacli" <<<"$l"' _ "$gh" "$(newest_dir)"
for need in brain .ssh ops; do
  mkguest; rm -rf "${gh:?}/$need"
  expect_msg 1 "/$need is missing" "a home without $need is refused, not backed up without it" run_nightly
  check "  ... and nothing was written or backed up ($need)" bash -c '{ [ ! -d "$1/backups" ] || [ -z "$(ls -A "$1/backups")" ]; } && ! grep -q "^openclaw" "$2"' _ "$gh" "$t/ev"
done

# --- the retired agent dirs and stale state dirs the old VM's export carried over ---
mkguest; mkdir -p "$gh/openclaw-agents-retired-20260101/agent" "$gh/.openclaw-stale-1/credentials"
echo r > "$gh/openclaw-agents-retired-20260101/agent/a"; echo s > "$gh/.openclaw-stale-1/credentials/keep.txt"
expect 0 "a run with a retired agent dir and a stale state dir next to ~/.openclaw completes" run_nightly
check "both land in filestate.tar.gz (found under HOME from any working directory)" bash -c 'l=$(tar -tzf "$1/backups/$2/filestate.tar.gz"); grep -q "^openclaw-agents-retired-20260101/agent/a$" <<<"$l" && grep -q "^.openclaw-stale-1/credentials/keep.txt$" <<<"$l"' _ "$gh" "$(newest_dir)"
mkguest
expect 0 "a run without any retired or stale dir completes" run_nightly
check "and archives no such path" bash -c '! tar -tzf "$1/backups/$2/filestate.tar.gz" | grep -Eq "retired|stale"' _ "$gh" "$(newest_dir)"

# --- tar exit codes: a file changing under tar (a live SQLite database) is not a failed night ---
mkguest; export FAKE_TAR_RC=1 FAKE_TAR_MSG='brain/app/live.db: file changed as we read it'
expect_msg 0 "WARNING: tar exited 1.*brain/app/live.db: file changed as we read it" "tar exit 1 does not fail the night, and the warning names tar's message" run_nightly
check "that night's backup was published and verifies" bash -c 'cd "$1/backups/$2" && grep -v "^mode=" MANIFEST | sha256sum --strict -c -' _ "$gh" "$(newest_dir)"
mkguest; export FAKE_TAR_RC=2 FAKE_TAR_MSG='brain/app/x: Cannot open: Permission denied'
expect_msg 1 "tar exited 2" "tar exit 2 (a real error) still fails the night" run_nightly
check "that run printed tar's message and left nothing behind" bash -c 'grep -q "Permission denied" "$1" && [ -z "$2" ]' _ "$t/out" "$(done_names)$(partial_names)"

# --- exactly one archive from openclaw ---
mkguest; export FAKE_ARCHIVES=0
expect_msg 1 "expected one backup archive .* found 0" "no archive from openclaw is refused" run_nightly
check "that run left nothing behind" test -z "$(done_names)$(partial_names)"
mkguest; export FAKE_ARCHIVES=2
expect_msg 1 "expected one backup archive .* found 2" "two archives from openclaw are refused, not one picked at random" run_nightly
check "that run left nothing behind either" test -z "$(done_names)$(partial_names)"

# --- a failing run leaves nothing half-written and prunes nothing ---
mkguest; for n in 1 2 3 4 5 6 7 8; do mkdone "$n"; done; export FAKE_OPENCLAW_FAIL=1
expect_msg 1 "failed; removed the incomplete" "a failing openclaw backup fails the run" run_nightly
check "the .partial of the failed run is gone" test -z "$(partial_names)"
check "a failed run releases the lock too" test ! -e "$gh/backups/.lock"
check "no complete dir appeared and none was pruned: all 8 earlier nightlies remain" test "$(done_names)" = "$(names_of 1 2 3 4 5 6 7 8)"

# --- retention ---
mkguest; for n in 1 2 3 4 5 6 7 8 9; do mkdone "$n"; done
touch -t 203001010000 "$gh/backups/claw-nightly-$(stamp 1)Z"   # oldest by name, newest by mtime: names decide
expect 0 "a run with nine earlier nightlies completes" run_nightly
nl=$(newest_dir)
check "exactly 7 complete dirs remain: the new one and the 6 newest by name" test "$(done_names)" = "$(names_of 4 5 6 7 8 9)$nl "
mkguest; for n in 1 2 3 4 5 6 7; do mkdone "$n"; done; mkpartial 20990101T000000Z
expect 0 "a run with seven nightlies and a stale newer-named .partial completes" run_nightly
nl=$(newest_dir)
check "the stale .partial was not counted: only the oldest nightly went" test "$(done_names)" = "$(names_of 2 3 4 5 6 7)$nl "
check "the stale .partial was swept after the successful run" test -z "$(partial_names)"
mkguest; for n in 1 2 3; do mkdone "$n"; done
expect 0 "fewer than 7 nightlies: nothing is pruned" run_nightly
nl=$(newest_dir)
check "all earlier nightlies are kept" test "$(done_names)" = "$(names_of 1 2 3)$nl "

# --- the new dir never overwrites or nests into an existing name ---
mkguest; mkdone 1; FAKE_DATE="$(stamp 1)Z"; export FAKE_DATE
expect_msg 1 "already exists" "a name collision is refused" run_nightly
check "the existing nightly is untouched and no .partial is left" test "$(done_names)$(partial_names)" = "$(names_of 1)"
check "the existing nightly did not get the new one nested inside it" bash -c '[ -z "$(ls "$1")" ] || [ "$(ls "$1" | LC_ALL=C sort | tr "\n" " ")" = "filestate.tar.gz openclaw-backup.tar.gz " ]' _ "$gh/backups/claw-nightly-$(stamp 1)Z"

# --- one run at a time ---
mkguest; mkdir -p "$gh/backups/.lock"; echo "$$" > "$gh/backups/.lock/pid"; mkpartial 20260101T000000Z
expect_msg 1 "another nightly backup holds .*\.lock \(pid $$\)" "a lock held by a live run refuses the second run" run_nightly
check "the refused run deleted no .partial, left the holder's lock and its pid alone, and never called openclaw" \
  bash -c '[ -d "$1/backups/claw-nightly-20260101T000000Z.partial" ] && [ "$(cat "$1/backups/.lock/pid")" = "$2" ] && ! grep -q "^openclaw" "$3"' _ "$gh" "$$" "$t/ev"
mkguest; mkdir -p "$gh/backups/.lock"
expect_msg 1 "another nightly backup holds" "a lock with no pid file cannot be told from a live one and refuses" run_nightly
mkguest; sleep 0 & dead=$!; wait "$dead"; mkdir -p "$gh/backups/.lock"; echo "$dead" > "$gh/backups/.lock/pid"; mkpartial 20260101T000000Z
expect 0 "a lock left by a run that is gone (killed, rebooted) is taken over" run_nightly
check "that run swept the stale .partial" test -z "$(partial_names)"
check "and released the lock it took over" test ! -e "$gh/backups/.lock"

# --- the bootstrap token: one shared parser (ops/lib/dotenv-token.sh), stricter than any loader ---
nightly_refuses() { # nightly_refuses <name> <message-regex> <dotenv content>
  mkguest; printf '%s\n' "$3" > "$gh/.openclaw/.env"
  expect_msg 1 "$2" "a .env with $1 is refused" run_nightly
  check "  ... and nothing was written or backed up ($1)" bash -c '{ [ ! -d "$1/backups" ] || [ -z "$(ls -A "$1/backups")" ]; } && ! grep -q "^openclaw" "$2" && [ ! -e "$3" ]' _ "$gh" "$t/ev" "$t/sourced"
}
nightly_refuses crlf "CRLF" $'OP_SERVICE_ACCOUNT_TOKEN=abc\r'
nightly_refuses crlf-elsewhere "CRLF" $'OTHER=1\r\nOP_SERVICE_ACCOUNT_TOKEN=abc'
nightly_refuses dup "set 2 times" $'OP_SERVICE_ACCOUNT_TOKEN=aaa\nOP_SERVICE_ACCOUNT_TOKEN=bbb'
nightly_refuses export-dup "set 2 times" $'OP_SERVICE_ACCOUNT_TOKEN=aaa\nexport OP_SERVICE_ACCOUNT_TOKEN=bbb'
nightly_refuses indented-dup "set 2 times" $'OP_SERVICE_ACCOUNT_TOKEN=aaa\n  OP_SERVICE_ACCOUNT_TOKEN=bbb'
nightly_refuses prefix-only-key "bootstrap token missing" 'OP_SERVICE_ACCOUNT_TOKEN_OLD=abc'
nightly_refuses empty-value "value is empty" 'OP_SERVICE_ACCOUNT_TOKEN='
nightly_refuses empty-quoted-value "value is empty" 'OP_SERVICE_ACCOUNT_TOKEN=""'
nightly_refuses inline-comment "contains '#'" 'OP_SERVICE_ACCOUNT_TOKEN=abc # the old one'
nightly_refuses whitespace "contains whitespace" 'OP_SERVICE_ACCOUNT_TOKEN=abc def'
nightly_refuses metachar-token "characters a dotenv file cannot carry" "OP_SERVICE_ACCOUNT_TOKEN=abc;touch\${IFS}$t/sourced"
nightly_accepts() { # nightly_accepts <name> <dotenv content>
  mkguest; printf '%s\n' "$2" > "$gh/.openclaw/.env"
  expect 0 "a .env with $1 is accepted" run_nightly
  check "  ... and nothing in it was executed ($1)" test ! -e "$t/sourced"
}
nightly_accepts export-prefix 'export OP_SERVICE_ACCOUNT_TOKEN=abc123'
nightly_accepts indented-key '   OP_SERVICE_ACCOUNT_TOKEN=abc123'
nightly_accepts quoted-value 'OP_SERVICE_ACCOUNT_TOKEN="abc123"'
nightly_accepts commented-out-line $'# OP_SERVICE_ACCOUNT_TOKEN=old\nOP_SERVICE_ACCOUNT_TOKEN=abc123'
nightly_accepts prefix-named-key-too $'OP_SERVICE_ACCOUNT_TOKEN_OLD=old\nOP_SERVICE_ACCOUNT_TOKEN=abc123'

# --- the script as import.sh final installs it: ops/backup next to ops/lib ---
mkguest; rm -rf "${t:?}/inst"; mkdir -p "$t/inst/ops/backup" "$t/inst/ops/lib"
cp "$nightly" "$t/inst/ops/backup/"; cp "$repo/ops/lib/dotenv-token.sh" "$t/inst/ops/lib/"
expect 0 "the nightly runs from an installed copy, finding its parser in ../lib" run_nightly_at "$t/inst/ops/backup/nightly-backup.sh"
mkguest; rm "$t/inst/ops/lib/dotenv-token.sh"
expect_msg 1 "dotenv-token\.sh is missing" "without its parser next to it the nightly refuses, with a message" run_nightly_at "$t/inst/ops/backup/nightly-backup.sh"

# --- free space: fail closed, before writing anything ---
margin_kb=1048576
mkguest; export FAKE_DF_AVAIL_KB=$((margin_kb - 1024))
expect_msg 1 "not enough free space.* 1024 MiB needed, 1023 MiB free" "first run: less than the 1 GiB margin is refused, with the numbers" run_nightly
check "the refused run wrote nothing and never called openclaw" bash -c '[ -z "$(ls -A "$1/backups")" ] && ! grep -q "^openclaw" "$2"' _ "$gh" "$t/ev"
mkguest; export FAKE_DF_AVAIL_KB=$((margin_kb + 1024))
expect 0 "first run: the margin alone is enough when there is no earlier nightly" run_nightly
mkguest; mkdone 1 3; export FAKE_DF_AVAIL_KB=$((margin_kb + 3072 - 1024))
expect_msg 1 "not enough free space.* MiB needed, [0-9]+ MiB free" "room for the margin but not for another nightly of the newest one's size is refused" run_nightly
check "that refused run wrote nothing and pruned nothing" test "$(done_names)$(partial_names)" = "$(names_of 1)"
mkguest; mkdone 1 3; export FAKE_DF_AVAIL_KB=$((margin_kb + 3072 + 1024))
expect 0 "room for the margin plus the newest nightly's size is enough" run_nightly
mkguest; mkdone 1 3; mkdone 2 1; export FAKE_DF_AVAIL_KB=$((margin_kb + 1024 + 1024))
expect 0 "the size term is the NEWEST nightly's (1 MiB), not the largest (3 MiB)" run_nightly
mkguest; mkdone 1 3; mkpartial 20990101T000000Z 10; export FAKE_DF_AVAIL_KB=$((margin_kb + 3072 + 1024))
expect 0 "a stale newer-named .partial does not count as the newest nightly for the size term" run_nightly

reset_fakes

# ===== Part 2: the host pull ========================================================================
# The host script is macOS-only (date -j, shasum, launchd), so this part needs macOS date(1) as well.
fg="$t/fguest"; hh="$t/host"; dest="$t/dest"; rrepo="$t/restic-repo"
mkgood() { # mkgood <n>: a complete, valid nightly dir in the fake guest
  local d; d="$fg/backups/claw-nightly-$(stamp "$1")Z"
  mkdir -p "$d"; chmod 700 "$d"; echo "backup $1" > "$d/openclaw-backup.tar.gz"; echo "files $1" > "$d/filestate.tar.gz"
  (cd "$d" && { echo mode=nightly; sum256 openclaw-backup.tar.gz filestate.tar.gz; } > MANIFEST)
}
mkhost() { # a fake guest, a host home and an existing restic repository (tests about init remove it)
  reset_fakes; rm -rf "$fg" "$hh" "$dest" "$rrepo" "$t/hev"; : > "$t/hev"
  mkdir -p "$fg/backups" "$hh" "$rrepo"; echo cfg > "$rrepo/config"
}
snap() { local n; for n in "$@"; do echo "$dest/claw-nightly-$(stamp "$n")Z" >> "$rrepo/snaps"; done; }   # snap <n>...: restic already holds a snapshot of night n
hmake() { mkdir -p "$dest/claw-nightly-$(stamp "$1")Z"; echo x > "$dest/claw-nightly-$(stamp "$1")Z/openclaw-backup.tar.gz"; }
epoch_of() { /bin/date -j -u -f %Y%m%dT%H%M%SZ "$1" +%s; }   # epoch_of 20200103T000000Z
# By default the host's clock is two hours after the newest night in the fake guest: fresh.
default_now() {
  local n; n=$({ cd "$fg/backups" 2>/dev/null && ls -d claw-nightly-[0-9]*Z 2>/dev/null; } | sort | tail -1) || true
  if [ -n "$n" ]; then echo $(( $(epoch_of "${n#claw-nightly-}") + 7200 )); fi
}
# Isolated from the caller's shell (a developer may well have RESTIC_* or CLAW_BACKUP_DEST exported).
pull_env() { env -u CLAW_INSTANCE -u CLAW_BACKUP_DEST -u RESTIC_REPOSITORY -u RESTIC_PASSWORD -u RESTIC_PASSWORD_COMMAND \
  HOME="$hh" FAKE_GUEST="$fg" FAKE_LOG="$t/hev" FAKE_NOW="${FAKE_NOW:-$(default_now)}" PATH="$t/hbin:$PATH" "$@"; }
run_pull() { pull_env CLAW_BACKUP_DEST="$dest" RESTIC_REPOSITORY="$rrepo" bash "$pull"; }
hev() { grep -Eq -- "$1" "$t/hev"; }
hdone() { { cd "$dest" 2>/dev/null && ls -d claw-nightly-*Z 2>/dev/null; } | tr '\n' ' ' || true; }
hpartial() { { cd "$dest" 2>/dev/null && ls -d claw-nightly-*.partial 2>/dev/null; } | tr '\n' ' ' || true; }
hin_order() { # hin_order <ere>...: the first event matching each pattern comes after the first matching the one before
  local prev=0 n pat
  for pat in "$@"; do
    n=$(grep -nE -- "$pat" "$t/hev" | head -1 | cut -d: -f1)
    if [ -z "$n" ] || [ "$n" -le "$prev" ]; then return 1; fi
    prev=$n
  done
}
bk() { echo "^restic backup --tag vm-claw $dest/claw-nightly-$(stamp "$1")Z \\|"; }   # bk <n>: the restic backup of night n, on its own path
nbk() { [ "$(grep -c "^restic backup" "$t/hev")" = "$1" ]; }                       # nbk <count>: how many backups restic was asked for
copy_of() { echo "^limactl shell --workdir / claw -- sudo -n -u sebastian -- tar -C /home/sebastian/backups -cf - claw-nightly-$(stamp "$1")Z\$"; }
hevF() { grep -qF -- "$1" "$t/hev"; }   # a literal fragment of the call log

# Damages to a night in the fake guest, for the gate tests and the bad-night tests.
zeros=$(printf '0%.0s' $(seq 1 64))
m_junk() { echo 'this is not a checksum line' >> "$1"; }
m_wronghash() { sed "s/^[0-9a-f]\{64\}  filestate/$zeros  filestate/" "$1" > "$1.new" && mv "$1.new" "$1"; }
m_shorthash() { sed 's/^[0-9a-f]\{64\}  openclaw-backup/deadbeef  openclaw-backup/' "$1" > "$1.new" && mv "$1.new" "$1"; }
m_uppercase() { awk '{ if ($2 == "filestate.tar.gz") $1 = toupper($1); print $1 (NF > 1 ? "  " $2 : "") }' "$1" > "$1.new" && mv "$1.new" "$1"; }
m_unlisted() { grep -v 'filestate.tar.gz' "$1" > "$1.new" && mv "$1.new" "$1"; }
m_badfile() { echo tampered >> "$(dirname "$1")/filestate.tar.gz"; }

# --- which backups are pulled: every complete one that is missing, oldest first ---
mkhost; mkgood 1; mkgood 2; mkgood 3; mkdir -p "$fg/backups/claw-nightly-20990101T000000Z.partial"; echo junk > "$fg/backups/claw-nightly-20990101T000000Z.partial/x"
touch -t 203001010000 "$fg/backups/claw-nightly-$(stamp 1)Z"   # oldest by name, newest by mtime: names decide
expect 0 "a pull completes" run_pull
check "all three missing nights were pulled, verified and are in place" test "$(hdone)" = "$(names_of 1 2 3)"
check "each is complete" bash -c 'for n in 1 2 3; do d="$1/claw-nightly-$(printf "202001%02dT000000" $n)Z"; [ -f "$d/MANIFEST" ] && [ -f "$d/filestate.tar.gz" ] && [ -f "$d/openclaw-backup.tar.gz" ] || exit 1; done' _ "$dest"
check "the guest's .partial was never pulled" bash -c '[ -z "$1" ] && [ ! -e "$2/claw-nightly-20990101T000000Z" ]' _ "$(hpartial)" "$dest"
check "oldest first, by name (not by mtime)" hin_order "$(copy_of 1)" "$(copy_of 2)" "$(copy_of 3)"
check "every night is streamed by the bot's tar from its backups dir" bash -c '[ "$(grep -c "^limactl shell --workdir / claw -- sudo -n -u sebastian -- tar -C /home/sebastian/backups -cf - " "$1")" = 3 ]' _ "$t/hev"
check "the dest dir is mode 700" test "$(mode_of "$dest")" = drwx------
check "a good pull prints no per-file OK lines from the checksum tool" bash -c '! grep -q ": OK" "$1"' _ "$t/out"
check "restic backs up each pulled night on its own path, tagged, oldest first, after the pulls, then forgets across them with the retention policy" \
  hin_order "$(copy_of 3)" "$(bk 1)" "$(bk 2)" "$(bk 3)" '^restic forget --tag vm-claw --group-by host --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune '
check "restic backed up three times (one per night), never the dest dir itself, and forgot once" \
  bash -c '[ "$(grep -c "^restic backup" "$1")" = 3 ] && ! grep -Eq "^restic backup .* $2( |\$)" "$1" && [ "$(grep -c "^restic forget" "$1")" = 1 ]' _ "$t/hev" "$dest"
check "the lock is released after the run" test ! -e "$dest/.lock"
check "the lock recorded the pid of the running pull while it copied" hev '^lockpid=[0-9]+$'
mkhost; mkgood 1; mkgood 2; mkgood 3; hmake 1; snap 1
expect 0 "a pull with one night already here completes" run_pull
check "only the missing nights were copied" bash -c '! grep -q " -cf - claw-nightly-$2Z$" "$1" && grep -q " -cf - claw-nightly-$3Z$" "$1" && grep -q " -cf - claw-nightly-$4Z$" "$1"' _ "$t/hev" "$(stamp 1)" "$(stamp 2)" "$(stamp 3)"
check "only nights without a snapshot were backed up: night 1 already has one and got no backup call, 2 and 3 got one each" \
  bash -c '! grep -Eq "^restic backup .*claw-nightly-$2Z" "$1"' _ "$t/hev" "$(stamp 1)"
check "  ... 2 and 3 got one each, and forget ran after both" hin_order "$(bk 2)" "$(bk 3)" '^restic forget '
check "  ... exactly two backups" nbk 2
mkhost; mkdir -p "$fg/backups/claw-nightly-20990101T000000Z.partial"
expect_msg 1 "no complete nightly" "a guest with only a .partial has nothing to pull" run_pull
check "restic did not run" bash -c '! grep -q "^restic" "$1"' _ "$t/hev"
mkhost; mkgood 1; export FAKE_LIMA_DOWN=1
expect_msg 1 "cannot list" "a guest that cannot be reached fails the run, with a message" run_pull
check "restic did not run" bash -c '! grep -q "^restic" "$1"' _ "$t/hev"
mkhost; mkgood 1; mkgood 2; mkdir -p "$fg/backups/claw-nightly-garbageZ"
expect_msg 1 "unexpected backup name 'claw-nightly-garbageZ'" "a name that is not a timestamp stops the run" run_pull
check "nothing was pulled (every name is checked first) and restic did not run" bash -c '[ -z "$1" ] && ! grep -Eq "^(limactl shell .* -- tar |restic)" "$2"' _ "$(hdone)" "$t/hev"

# --- a pulled nightly is not pulled again ---
mkhost; mkgood 1; run_pull >/dev/null 2>&1 || true   # the first pull; its own test is above
: > "$t/hev"
expect 0 "a second pull of the same nightly completes" run_pull
check "it did not copy again" bash -c '! grep -q " -- tar -C " "$1"' _ "$t/hev"
check "it made no restic backup call (the night is already stored)" bash -c '! grep -q "^restic backup" "$1"' _ "$t/hev"
check "it still ran forget (retention keeps counting nights)" hev '^restic forget --tag vm-claw --group-by host '
check "the stamp is still written: a run with no new night is a success" test -f "$fg/backups/.host-pull-ok"

# --- the guest has stopped producing nightlies: restic still gets what exists, then the run fails ---
mkhost; mkgood 3; FAKE_NOW=$(( $(epoch_of "$(stamp 3)Z") + 31 * 3600 )); export FAKE_NOW
expect_msg 1 "is 31 h old \(limit 30 h\).*stopped producing" "a newest guest nightly older than 30 h fails the run, loudly" run_pull
check "  ... but restic still backed up what exists, and forgot" hin_order '^restic backup ' '^restic forget '
check "  ... and the night it found was pulled first" test "$(hdone)" = "$(names_of 3)"
mkhost; mkgood 3; FAKE_NOW=$(( $(epoch_of "$(stamp 3)Z") + 29 * 3600 )); export FAKE_NOW
expect 0 "a newest guest nightly 29 h old is fresh" run_pull
mkhost; mkgood 1; mkgood 3; FAKE_NOW=$(( $(epoch_of "$(stamp 3)Z") + 2 * 3600 )); export FAKE_NOW
expect 0 "freshness is judged on the NEWEST night: an old one next to a fresh one is fine" run_pull
mkhost; mkgood 3; FAKE_NOW=$(( $(epoch_of "$(stamp 3)Z") - 2 * 3600 )); export FAKE_NOW
expect_msg 1 "dated 120 min in the future \(limit 1 h\)" "a newest guest nightly dated 2 h in the future fails the run" run_pull
check "  ... after restic ran" hin_order '^restic backup ' '^restic forget '
mkhost; mkgood 3; FAKE_NOW=$(( $(epoch_of "$(stamp 3)Z") - 1800 )); export FAKE_NOW
expect 0 "a newest guest nightly dated 30 min ahead is within the clock-skew allowance" run_pull

# --- one bad night does not cost the good ones, or restic ---
bad_night_checks() { # after a run in which night 2 of 1, 2, 3 failed
  check "  ... both good nights were pulled, the bad one is not kept and leaves no .partial" test "$(hdone)$(hpartial)" = "$(names_of 1 3)"
  check "  ... restic still backed up and forgot" hin_order '^restic backup ' '^restic forget '
  check "  ... each good night got its own backup, the failed night (2) none, and nothing else" bash -c 'grep -Eq "^restic backup .*claw-nightly-$2Z " "$1" && grep -Eq "^restic backup .*claw-nightly-$3Z " "$1" && ! grep -Eq "^restic backup .*claw-nightly-$4Z" "$1" && [ "$(grep -c "^restic backup" "$1")" = 2 ]' _ "$t/hev" "$(stamp 1)" "$(stamp 3)" "$(stamp 2)"
  check "  ... the last log line names the failed night" bash -c 'tail -1 "$1" | grep -q "FAILED nights.*claw-nightly-$2Z"' _ "$t/out" "$(stamp 2)"
}
mkhost; mkgood 1; mkgood 2; mkgood 3; m_wronghash "$fg/backups/claw-nightly-$(stamp 2)Z/MANIFEST"
expect_msg 1 "claw-nightly-$(stamp 2)Z: it failed verification" "a night that fails the gate between two good ones fails the run, loudly" run_pull
bad_night_checks
mkhost; mkgood 1; mkgood 2; mkgood 3; FAKE_COPY_VANISH="claw-nightly-$(stamp 2)Z"; export FAKE_COPY_VANISH
expect_msg 1 "claw-nightly-$(stamp 2)Z: the copy from the guest failed" "a night that disappears from the guest mid-copy fails the run, loudly" run_pull
bad_night_checks
mkhost; hmake 1; snap 1; mkgood 2; m_wronghash "$fg/backups/claw-nightly-$(stamp 2)Z/MANIFEST"
expect_msg 1 "claw-nightly-$(stamp 2)Z: it failed verification" "a failed night with an older complete night already here fails the run" run_pull
check "  ... restic ran forget (a complete night exists in the dest) but made no backup call: the only candidate failed, the other already has a snapshot" \
  bash -c 'grep -q "^restic forget" "$1" && ! grep -q "^restic backup" "$1"' _ "$t/hev"
mkhost; mkgood 1; m_wronghash "$fg/backups/claw-nightly-$(stamp 1)Z/MANIFEST"
expect_msg 1 "no complete night in .* nothing to send to restic" "a failed night with nothing else in the dest fails the run" run_pull
check "  ... and restic did not run (nothing complete to send)" bash -c '! grep -q "^restic" "$1"' _ "$t/hev"
mkhost; mkgood 2; mkgood 3; m_wronghash "$fg/backups/claw-nightly-$(stamp 2)Z/MANIFEST"; FAKE_NOW=$(( $(epoch_of "$(stamp 3)Z") + 31 * 3600 )); export FAKE_NOW
expect_msg 1 "is 31 h old" "a stale guest and a failed night are both reported" run_pull
check "  ... with the failed night named last" bash -c 'tail -1 "$1" | grep -q "FAILED nights.*claw-nightly-$2Z"' _ "$t/out" "$(stamp 2)"

# --- per-night snapshots: a run with no new night, and what the sweep removes ---
mkhost; mkgood 3; hmake 3; snap 3; echo x > "$dest/claw-nightly-$(stamp 3)Z/MANIFEST"; FAKE_NOW=$(( $(epoch_of "$(stamp 3)Z") + 31 * 3600 )); export FAKE_NOW
expect_msg 1 "is 31 h old" "a run with no new night still reaches the staleness check, and fails on it" run_pull
check "  ... with no backup call, but forget still ran" bash -c 'grep -q "^restic forget" "$1" && ! grep -q "^restic backup" "$1"' _ "$t/hev"
mkhost; for n in $(seq 1 16); do mkgood "$n"; done
expect 0 "sixteen new nights (the keep is 14) pull and snapshot" run_pull
check "  ... the two the keep sweep removed were never snapshotted (their paths are gone), the other fourteen were, once each" \
  bash -c '[ "$(grep -c "^restic backup" "$1")" = 14 ] && ! grep -Eq "^restic backup .*claw-nightly-$2Z |^restic backup .*claw-nightly-$3Z " "$1" && grep -Eq "^restic backup .*claw-nightly-$4Z " "$1"' _ "$t/hev" "$(stamp 1)" "$(stamp 2)" "$(stamp 3)"

# --- a night in dest that restic has no snapshot of is backed up on the next run (a failed backup is retried) ---
mkhost; mkgood 1; mkgood 2; export FAKE_RESTIC_FAIL=backup
expect 1 "a run whose restic backup fails fails" run_pull
check "  ... the nights stay in dest and restic holds no snapshot of them" bash -c '[ ! -s "$1/snaps" ] && [ -n "$2" ]' _ "$rrepo" "$(hdone)"
unset FAKE_RESTIC_FAIL; : > "$t/hev"
expect 0 "the next run (nothing new to pull) completes" run_pull
check "  ... it did not copy anything, yet backed up both nights, oldest first, each on its own path" \
  bash -c '! grep -q " -- tar -C " "$1"' _ "$t/hev"
check "  ... in order" hin_order '^restic snapshots --json --tag vm-claw' "$(bk 1)" "$(bk 2)" '^restic forget '
check "  ... exactly two backups" nbk 2
: > "$t/hev"
expect 0 "and the run after that" run_pull
check "  ... backs up nothing again: both nights now have a snapshot" bash -c '! grep -q "^restic backup" "$1"' _ "$t/hev"
mkhost; mkgood 2; mkgood 3; hmake 1; snap 1;
echo "$dest" >> "$rrepo/snaps"   # the old folder-level snapshot of the whole dest
: > "$t/hev"
expect 0 "a repository holding the old folder-level snapshot and night 1" run_pull
check "  ... the folder snapshot matches no night: 2 and 3 are backed up, 1 is not" bash -c 'grep -Eq "^restic backup .*claw-nightly-$2Z " "$1" && grep -Eq "^restic backup .*claw-nightly-$3Z " "$1" && [ "$(grep -c "^restic backup" "$1")" = 2 ]' _ "$t/hev" "$(stamp 2)" "$(stamp 3)"
mkhost; mkgood 1; mkgood 2; mkgood 3; rm -rf "$rrepo"
expect 0 "a brand-new repository (empty listing)" run_pull
check "  ... every night is snapshotted, after init and the listing" bash -c 'grep -c "^restic backup" "$1" | grep -qx 3' _ "$t/hev"
check "  ... in order" hin_order '^restic init ' '^restic snapshots --json' "$(bk 1)" "$(bk 2)" "$(bk 3)"

# --- one pull at a time ---
mkhost; mkgood 1; mkdir -p "$dest/.lock" "$dest/claw-nightly-20260101T000000Z.partial"; echo "$$" > "$dest/.lock/pid"
expect_msg 1 "another pull holds .*\.lock \(pid $$\)" "a lock held by a live pull refuses the second pull" run_pull
check "the refused pull deleted no .partial, left the holder's lock and its pid alone, and never copied or ran restic" \
  bash -c '[ -d "$1/claw-nightly-20260101T000000Z.partial" ] && [ "$(cat "$1/.lock/pid")" = "$2" ] && ! grep -Eq "^(limactl shell .* -- tar |restic)" "$3"' _ "$dest" "$$" "$t/hev"
mkhost; mkgood 1; mkdir -p "$dest/.lock"
expect_msg 1 "another pull holds" "a lock with no pid file cannot be told from a live one and refuses" run_pull
mkhost; mkgood 1; sleep 0 & dead=$!; wait "$dead"; mkdir -p "$dest/.lock" "$dest/claw-nightly-20260101T000000Z.partial"; echo "$dead" > "$dest/.lock/pid"
expect 0 "a lock left by a pull that is gone (killed, Mac restarted) is taken over" run_pull
check "that pull swept the stale .partial" test -z "$(hpartial)"
check "and released the lock it took over" test ! -e "$dest/.lock"
mkhost; mkgood 1; export FAKE_COPY_FAIL=1
expect 1 "a failing pull fails the run" run_pull
check "a failed pull releases the lock" test ! -e "$dest/.lock"

# --- retention on the host ---
mkhost; mkgood 20; for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do hmake "$n"; done
mkdir -p "$dest/claw-nightly-20990101T000000Z.partial"
touch -t 203001010000 "$dest/claw-nightly-$(stamp 1)Z"   # oldest by name, newest by mtime: names decide
expect 0 "a pull over 15 earlier nightlies completes" run_pull
check "exactly 14 complete dirs remain: the new one and the 13 newest by name" \
  test "$(hdone)" = "$(names_of 3 4 5 6 7 8 9 10 11 12 13 14 15 20)"
check "the stale newer-named .partial was swept too" test -z "$(hpartial)"
mkhost; mkgood 20; for n in 1 2 3; do hmake "$n"; done
expect 0 "a pull over three earlier nightlies completes" run_pull
check "fewer than 14 nightlies: nothing is pruned" test "$(hdone)" = "$(names_of 1 2 3 20)"

# --- the checksum gate on the host ---
gate_case() { # gate_case <description> <message-regex> <mutation-of-night-1's-MANIFEST>: night 1 fails, night 2 is good
  local desc="$1" pat="$2"; shift 2
  mkhost; mkgood 1; mkgood 2; "$@" "$fg/backups/claw-nightly-$(stamp 1)Z/MANIFEST"
  expect_msg 1 "$pat" "$desc" run_pull
  check "  ... the failed night is never kept: not in the dest, no .partial, and the good night after it is" test "$(hdone)$(hpartial)" = "$(names_of 2)"
  check "  ... and the last log line names the failed night" bash -c 'tail -1 "$1" | grep -q "FAILED nights.*claw-nightly-$2Z"' _ "$t/out" "$(stamp 1)"
}
gate_case "a MANIFEST line the checker cannot parse is refused (--strict)" "failed verification" m_junk
gate_case "a well-formed but wrong sha256 is refused, and the log names the file that failed" "filestate.tar.gz: FAILED" m_wronghash
gate_case "a malformed hash for a listed file is refused" "failed verification" m_shorthash
gate_case "an uppercase hash is refused (64 lowercase hex, as sha256sum writes)" "failed verification" m_uppercase
gate_case "a MANIFEST that does not list both files is refused" "failed verification" m_unlisted
gate_case "an archive that does not match its MANIFEST is refused, and the log names it" "filestate.tar.gz: FAILED" m_badfile

# --- partial copies ---
mkhost; mkgood 1; mkdir -p "$dest/claw-nightly-$(stamp 1)Z.partial"; echo stale > "$dest/claw-nightly-$(stamp 1)Z.partial/stale-file"
expect 0 "a stale .partial of the same name from an earlier killed run does not break the pull" run_pull
check "the copy landed in place, not nested in the stale dir, and carries no stale file" \
  bash -c '[ -f "$1/MANIFEST" ] && [ ! -e "$1/stale-file" ] && [ ! -e "$1/claw-nightly-$2Z.partial" ]' _ "$dest/claw-nightly-$(stamp 1)Z" "$(stamp 1)"
check "no .partial is left" test -z "$(hpartial)"
mkhost; mkgood 1; export FAKE_COPY_FAIL=1
expect 1 "a stream whose guest side fails after sending everything (pipefail) fails the run" run_pull
check "the half-copied .partial was removed" test -z "$(hdone)$(hpartial)"
check "restic did not run" bash -c '! grep -q "^restic" "$1"' _ "$t/hev"

# --- the guest side runs as the bot account (spec 2026-10-02 §3) ---
mkhost; mkgood 1; mkgood 2; chmod 755 "$fg/backups/claw-nightly-$(stamp 1)Z"   # the pull, not the guest, sets 700
expect 0 "a pull from the bot's backups completes" run_pull
check "the listing ran as the bot, over its backups dir" hevF 'limactl shell --workdir / claw -- sudo -n -u sebastian -- bash -c ls -d "$1"/claw-nightly-*Z 2>/dev/null | sort _ /home/sebastian/backups'
check "each night was streamed by the bot's tar" bash -c '[ "$(grep -c "^limactl shell --workdir / claw -- sudo -n -u sebastian -- tar -C /home/sebastian/backups -cf - claw-nightly-" "$1")" = 2 ]' _ "$t/hev"
check "the stamp was written by the bot, through a temp file" hevF 'limactl shell --workdir / claw -- sudo -n -u sebastian -- bash -c umask 077; date -u +%Y-%m-%dT%H:%M:%SZ > "$1/.host-pull-ok.tmp" && mv "$1/.host-pull-ok.tmp" "$1/.host-pull-ok" _ /home/sebastian/backups'
check "a pulled night is mode 700 and its files 600" \
  bash -c '[ "$(ls -ld "$1" | cut -c1-10)" = drwx------ ] && [ -z "$(find "$1" -type f ! -perm 600)" ]' _ "$dest/claw-nightly-$(stamp 1)Z"
mkhost; mkgood 1; mkgood 2; echo planted > "$fg/backups/claw-nightly-$(stamp 1)Z/extra"
expect_msg 1 "claw-nightly-$(stamp 1)Z: it failed verification" "a night that carries a file a nightly never writes is not kept" run_pull
check "  ... and the good night is" test "$(hdone)$(hpartial)" = "$(names_of 2)"
mkhost; mkgood 1; mkgood 2; d1="$fg/backups/claw-nightly-$(stamp 1)Z"
cp "$d1/filestate.tar.gz" "$t/elsewhere"; rm "$d1/filestate.tar.gz"; ln -s "$t/elsewhere" "$d1/filestate.tar.gz"
expect_msg 1 "claw-nightly-$(stamp 1)Z: it failed verification" "a night whose archive arrives as a symlink is not kept, even when its checksum matches" run_pull
check "  ... and nothing of it is in the dest" test "$(hdone)$(hpartial)" = "$(names_of 2)"
mkhost; mkgood 1; ln -s "../claw-nightly-$(stamp 1)Z" "$fg/backups/claw-nightly-$(stamp 2)Z"
expect_msg 1 "claw-nightly-$(stamp 2)Z: it failed verification" "a night that is itself a symlink is not kept, not even as a dangling link" run_pull
check "  ... nothing of it is in the dest (no link, no .partial), the real night is" bash -c '[ ! -L "$1/claw-nightly-$2Z" ] && [ ! -e "$1/claw-nightly-$2Z" ] && [ -d "$1/claw-nightly-$3Z" ]' _ "$dest" "$(stamp 2)" "$(stamp 1)"
check "  ... and no stamp was written" test ! -e "$fg/backups/.host-pull-ok"
mkhost; mkgood 1; mkgood 2; m_wronghash "$fg/backups/claw-nightly-$(stamp 1)Z/MANIFEST"; chmod 500 "$fg/backups/claw-nightly-$(stamp 1)Z"
expect_msg 1 "claw-nightly-$(stamp 1)Z: it failed verification" "a failing night whose directory arrives read-only is named, not a crash" run_pull
check "  ... and leaves no .partial; the good night is kept" test "$(hdone)$(hpartial)" = "$(names_of 2)"
chmod 700 "$fg/backups/claw-nightly-$(stamp 1)Z"; mkgood 1
expect 0 "  ... and the next run, over a repaired night, proceeds normally" run_pull
mkhost; mkgood 1
expect 0 "a pull with CLAW_INSTANCE set" pull_env CLAW_INSTANCE=claw-next CLAW_BACKUP_DEST="$dest" RESTIC_REPOSITORY="$rrepo" bash "$pull"
check "  ... sent every guest command to that instance" bash -c 'grep -q "^limactl shell --workdir / claw-next -- " "$1" && ! grep -q "^limactl shell --workdir / claw -- " "$1"' _ "$t/hev"
mkhost; mkgood 1
expect_msg 1 "not an instance name" "a CLAW_INSTANCE that is not an instance name is refused" pull_env 'CLAW_INSTANCE=x;y' CLAW_BACKUP_DEST="$dest" RESTIC_REPOSITORY="$rrepo" bash "$pull"
check "  ... before any guest command" bash -c '! grep -q "^limactl" "$1"' _ "$t/hev"

# --- restic: init only for a repository that does not exist ---
mkhost; mkgood 1; echo "old stamp" > "$fg/backups/.host-pull-ok"; export FAKE_SNAPSHOTS_FAIL=1
expect 1 "a failing 'restic snapshots' (evicted file, locked keychain) fails the run, never 'nothing to back up'" run_pull
check "  ... restic init never ran (the repository's config exists), no backup and no forget was attempted" bash -c '! grep -Eq "^restic (init|backup|forget)" "$1"' _ "$t/hev"
check "  ... and the stamp is untouched" bash -c '[ "$(cat "$1")" = "old stamp" ] && ! grep -q "host-pull-ok" "$2"' _ "$fg/backups/.host-pull-ok" "$t/hev"
mkhost; mkgood 1; rm -rf "$rrepo"
expect 0 "a first run creates the repository" run_pull
check "restic init ran, once, before the snapshots listing and the first backup" hin_order '^restic init ' '^restic snapshots --json --tag vm-claw' '^restic backup '
check "init ran once" bash -c '[ "$(grep -c "^restic init" "$1")" = 1 ]' _ "$t/hev"
mkhost; mkgood 1; rm -rf "$rrepo"; mkdir -p "$rrepo/data"; echo blob > "$rrepo/data/x"
expect_msg 1 "no config" "a repository dir with content but no config file (something is evicted) is not re-initialised" run_pull
check "restic did not run at all" bash -c '! grep -q "^restic" "$1"' _ "$t/hev"

# --- restic: the caller's settings win ---
mkhost; mkgood 1
expect 0 "a pull with a pre-set repository (and no iCloud Drive at all)" run_pull
check "a pre-set RESTIC_REPOSITORY is honoured" hev "^restic backup .*repo=$rrepo "
mkhost; mkgood 1; mkdir -p "$hh/Library/Mobile Documents/com~apple~CloudDocs"
expect 0 "a pull with no RESTIC_* settings and iCloud Drive on" pull_env CLAW_BACKUP_DEST="$dest" bash "$pull"
check "the default repository is in iCloud Drive under Backups/vm-claw-restic" hev '^restic backup .*repo=.*/Library/Mobile Documents/com~apple~CloudDocs/Backups/vm-claw-restic '
mkhost; mkgood 1
expect_msg 1 "iCloud Drive is off" "the default repository with iCloud Drive off is refused, not created as a local directory" pull_env CLAW_BACKUP_DEST="$dest" bash "$pull"
check "no local repository appeared under the home, and restic did not run" bash -c '[ ! -e "$1/Library" ] && ! grep -q "^restic" "$2"' _ "$hh" "$t/hev"
check "the nights were still pulled before it stopped" test "$(hdone)" = "$(names_of 1)"
mkhost; mkgood 1
expect 0 "a pull with no password set" run_pull
check "the keychain password command is the default" hev 'pwcmd=security find-generic-password -s vm-claw-restic -w$'
check "that command is what restic ran (the fake keychain was asked for the vm-claw-restic item)" hev '^security find-generic-password -s vm-claw-restic -w$'
mkhost; mkgood 1
expect 0 "a pull with RESTIC_PASSWORD set" pull_env CLAW_BACKUP_DEST="$dest" RESTIC_REPOSITORY="$rrepo" RESTIC_PASSWORD=preset bash "$pull"
check "a pre-set RESTIC_PASSWORD is honoured: no password command is added" hev '^restic backup .*pw=set pwcmd=<unset>$'
check "the keychain was not asked" bash -c '! grep -q "^security" "$1"' _ "$t/hev"
mkhost; mkgood 1
expect 0 "a pull with RESTIC_PASSWORD_COMMAND set" pull_env CLAW_BACKUP_DEST="$dest" RESTIC_REPOSITORY="$rrepo" RESTIC_PASSWORD_COMMAND='echo preset' bash "$pull"
check "a pre-set RESTIC_PASSWORD_COMMAND is honoured, not replaced by the keychain one" hev '^restic backup .*pwcmd=echo preset$'
check "the keychain was not asked either" bash -c '! grep -q "^security" "$1"' _ "$t/hev"

# --- the host-pull stamp: written into the guest only after a fully successful run (backup-health.mjs reads it) ---
stampf() { echo "$fg/backups/.host-pull-ok"; }
mkhost; mkgood 1
expect 0 "a fully successful pull completes" run_pull
check "it left the stamp in the guest: one UTC timestamp line" bash -c 'grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" "$1" && [ "$(wc -l < "$1")" -eq 1 ]' _ "$(stampf)"
check "  ... mode 600, and no temp file left behind" bash -c '[ "$(/usr/bin/stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1")" = 600 ] && [ ! -e "$1.tmp" ]' _ "$(stampf)"
check "  ... written through a temp file and renamed (atomic), after restic and the checks" hin_order '^restic forget ' '^limactl shell --workdir / claw -- sudo -n -u sebastian -- bash -c .*> "\$1/\.host-pull-ok\.tmp" && mv "\$1/\.host-pull-ok\.tmp" "\$1/\.host-pull-ok" _ /home/sebastian/backups$'
no_stamp_checks() { # a pre-existing stamp is neither replaced nor removed, and none is created
  check "  ... the stamp is untouched" bash -c '[ ! -e "$1" ] || [ "$(cat "$1")" = "old stamp" ]' _ "$(stampf)"
  check "  ... and no stamp command was sent to the guest" bash -c '! grep -q "host-pull-ok" "$1"' _ "$t/hev"
}
mkhost; mkgood 1; mkgood 2; mkgood 3; m_wronghash "$fg/backups/claw-nightly-$(stamp 2)Z/MANIFEST"; echo "old stamp" > "$(stampf)"
expect 1 "a failed night fails the run" run_pull
no_stamp_checks
mkhost; mkgood 1; echo "old stamp" > "$(stampf)"; export FAKE_RESTIC_FAIL=backup
expect 1 "a restic backup failure fails the run" run_pull
no_stamp_checks
mkhost; mkgood 1; echo "old stamp" > "$(stampf)"; export FAKE_RESTIC_FAIL=forget
expect 1 "a restic forget failure fails the run" run_pull
no_stamp_checks
mkhost; mkgood 3; echo "old stamp" > "$(stampf)"; FAKE_NOW=$(( $(epoch_of "$(stamp 3)Z") + 31 * 3600 )); export FAKE_NOW
expect 1 "the staleness alarm fails the run" run_pull
no_stamp_checks
mkhost; mkgood 3; echo "old stamp" > "$(stampf)"; FAKE_NOW=$(( $(epoch_of "$(stamp 3)Z") - 2 * 3600 )); export FAKE_NOW
expect 1 "the future-dated alarm fails the run" run_pull
no_stamp_checks
mkhost; mkgood 1; echo "old stamp" > "$(stampf)"
expect_msg 1 "iCloud Drive is off" "the iCloud-off refusal fails the run" pull_env CLAW_BACKUP_DEST="$dest" bash "$pull"
no_stamp_checks
mkhost; mkgood 1; export FAKE_STAMP_FAIL=1
expect_msg 1 "pull-backups: could not write the host-pull stamp" "a stamp that cannot be written fails the run with one clear line" run_pull
check "  ... after restic ran, and the nights are kept" bash -c 'grep -q "^restic forget" "$1" && [ -n "$2" ]' _ "$t/hev" "$(hdone)"

# --- PATH ---
# launchd's PATH has no Homebrew, so the script adds it; it must add it AFTER the caller's PATH, or the fakes
# above would be shadowed by the real limactl and restic (and these tests would reach the real VM).
check "the script appends Homebrew to PATH instead of prepending it" grep -q '^export PATH="\$PATH:/opt/homebrew/bin"$' "$pull"

# --- the destination ---
mkhost; mkgood 1
expect 0 "a pull with a pre-set CLAW_BACKUP_DEST" run_pull
check "a pre-set CLAW_BACKUP_DEST is where the backup lands, and the home's Backups dir is untouched" bash -c '[ -d "$1/claw-nightly-$2Z" ] && [ ! -e "$3/Backups" ]' _ "$dest" "$(stamp 1)" "$hh"
mkhost; mkgood 1
expect 0 "a pull with no CLAW_BACKUP_DEST" pull_env RESTIC_REPOSITORY="$rrepo" bash "$pull"
check "the default destination is ~/Backups/vm-claw" test -d "$hh/Backups/vm-claw/claw-nightly-$(stamp 1)Z"

# ===== Part 3: the units and the launchd plist ======================================================
svc="$here/openclaw-nightly-backup.service"; tmr="$here/openclaw-nightly-backup.timer"; plist="$repo/host/local.vm-claw.pull-backups.plist"
check "the service runs the script import.sh installs, from the guest user's home" grep -q '^ExecStart=/bin/bash %h/ops/backup/nightly-backup\.sh$' "$svc"
check "the service is a oneshot" grep -q '^Type=oneshot$' "$svc"
# The unit name is read out of import.sh's `enable --now <name>.timer` (whatever it says), not assumed here.
enabled_timer=$(grep -o 'enable --now [^ ;]*nightly[^ ;]*\.timer' "$repo/migrate/import.sh" | head -1 | sed 's/^enable --now //' || true)
check "import.sh enables a nightly timer" test -n "$enabled_timer"
check "that timer is in ops/backup under that name, has a [Timer] section, and sets no Unit= of its own" \
  bash -c '[ -n "$1" ] && grep -q "^\[Timer\]$" "$2/$1" && ! grep -q "^Unit=" "$2/$1"' _ "$enabled_timer" "$here"
check "so it starts the service of the same name, which is in ops/backup too" bash -c '[ -n "$1" ] && [ -f "$2/${1%.timer}.service" ]' _ "$enabled_timer" "$here"
check "the timer fires at 03:30 UTC" grep -q '^OnCalendar=\*-\*-\* 03:30:00 UTC$' "$tmr"
check "the timer catches up after downtime" grep -q '^Persistent=true$' "$tmr"
check "the timer is wanted by timers.target" grep -q '^WantedBy=timers\.target$' "$tmr"
check "import.sh installs and enables these units by these names" bash -c 'grep -q "openclaw-nightly-backup.timer" "$1" && grep -q "ops/backup/nightly-backup.sh" "$1"' _ "$repo/migrate/import.sh"
check "the plist's label is local.vm-claw.pull-backups" grep -q '<key>Label</key><string>local\.vm-claw\.pull-backups</string>' "$plist"
check "the plist runs the script from @REPO@ and logs under @HOME@ (host/install.sh substitutes them)" \
  bash -c 'grep -q "<string>@REPO@/host/pull-backups.sh</string>" "$1" && [ "$(grep -c "@HOME@/Library/Logs/vm-claw-pull-backups.log" "$1")" = 2 ]' _ "$plist"
check "the plist schedules 06:15" bash -c 'grep -q "<key>Hour</key><integer>6</integer><key>Minute</key><integer>15</integer>" "$1"' _ "$plist"
check "the plist hands the pull its instance (@INSTANCE@, substituted by host/install.sh)" \
  grep -qF '<key>EnvironmentVariables</key><dict><key>CLAW_INSTANCE</key><string>@INSTANCE@</string></dict>' "$plist"
if command -v plutil >/dev/null 2>&1; then check "the plist is valid" plutil -lint "$plist"; fi

echo "backup scripts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
