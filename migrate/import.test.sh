#!/bin/bash
# Guard-rail tests for import.sh and export.sh.
# Part 1 needs no OpenClaw: IMPORT_DRY=1 stops import.sh after validation.
# Part 2 runs import.sh for real against fake openclaw/systemctl/npm/op commands, so ordering and
# partial-failure behaviour can be checked. Part 3 runs export.sh against a fake home.
# The bash -c snippets below are single-quoted on purpose: they expand inside the child shell.
# shellcheck disable=SC2016
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
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
  else fail=$((fail+1)); echo "FAIL: $desc"; if [ -s "$t/ev" ]; then sed 's/^/    event: /' "$t/ev" | tail -12; fi; fi
}
sum256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }
manifest() { (cd "$1" && { echo "mode=$2"; sum256 openclaw-backup.tar.gz filestate.tar.gz; } > MANIFEST); }
mk() { # mk <dir> <mode> <wa-creds-in-backup:yes|no|other|backup> [filestate: creds (default) | plain | wacli]
  local files=(.openclaw/credentials)
  mkdir -p "$1/src/.openclaw/credentials"
  case "$3" in
    yes)    mkdir -p "$1/src/.openclaw/credentials/whatsapp/default"; echo '{}' > "$1/src/.openclaw/credentials/whatsapp/default/creds.json" ;;
    other)  mkdir -p "$1/src/.openclaw/credentials/whatsapp/second"; echo '{}' > "$1/src/.openclaw/credentials/whatsapp/second/creds.json" ;;
    backup) mkdir -p "$1/src/.openclaw/credentials/whatsapp.backup.20260101"; echo '{}' > "$1/src/.openclaw/credentials/whatsapp.backup.20260101/creds.json" ;;
  esac
  case "${4:-}" in
    plain) echo x > "$1/src/.openclaw/notes"; files=(.openclaw/notes) ;;
    wacli) mkdir -p "$1/src/.wacli"; echo x > "$1/src/.wacli/session.db"; files=(.wacli) ;;
  esac
  tar -C "$1/src" -czf "$1/openclaw-backup.tar.gz" .openclaw
  tar -C "$1/src" -czf "$1/filestate.tar.gz" "${files[@]}"
  rm -rf "$1/src"
  manifest "$1" "$2"
}
export IMPORT_DRY=1 IMPORT_HOME="$t/home"
mkdir -p "$t/home"

# ===== Part 1: validation (IMPORT_DRY=1) ==========================================================
mk "$t/reh" rehearsal no
expect 0 "rehearsal archive imports as rehearsal" bash "$here/import.sh" rehearsal "$t/reh"
expect 1 "rehearsal archive refused as final"     bash "$here/import.sh" final "$t/reh"

mk "$t/fin" final yes
expect 0 "final archive imports as final"          bash "$here/import.sh" final "$t/fin"
mk "$t/nig" nightly yes
expect 0 "nightly archive imports as final"        bash "$here/import.sh" final "$t/nig"
# A final-labelled archive is already refused by the mode check; the other two carry the rehearsal
# label, so only the WhatsApp-credential check can refuse them: credentials inside the OpenClaw
# backup (rwa), or a wacli session inside the file state (rws).
mk "$t/rwa" rehearsal yes plain
mk "$t/rws" rehearsal no wacli
refuses_as_rehearsal() { local d rc; for d in "$@"; do rc=0; bash "$here/import.sh" rehearsal "$d" || rc=$?; [ "$rc" -eq 1 ] || return 1; done; }
expect 0 "archive with WA creds refused as rehearsal" refuses_as_rehearsal "$t/fin" "$t/rwa" "$t/rws"
# Credentials under another account id, or only as a backup copy, must be refused too (not just
# credentials/whatsapp/default/creds.json).
mk "$t/rwo" rehearsal other plain
mk "$t/rwb" rehearsal backup plain
expect_msg 1 "WhatsApp credentials" "rehearsal refuses creds under another account id" bash "$here/import.sh" rehearsal "$t/rwo"
expect_msg 1 "WhatsApp credentials" "rehearsal refuses a whatsapp.backup.* copy"        bash "$here/import.sh" rehearsal "$t/rwb"

mk "$t/bad" final yes; echo x >> "$t/bad/filestate.tar.gz"
expect 1 "checksum mismatch refused"               bash "$here/import.sh" final "$t/bad"

# The checksum gate itself, with archives tar can read: a wrong (but well-formed) hash, a line the
# checker cannot parse, a malformed hash for a listed file, and a missing file entry.
zeros=$(printf '0%.0s' $(seq 1 64))
mk "$t/wh" final no plain
sed "s/^[0-9a-f]\{64\}  filestate/$zeros  filestate/" "$t/wh/MANIFEST" > "$t/wh/M" && mv "$t/wh/M" "$t/wh/MANIFEST"
expect_msg 1 "checksum mismatch" "well-formed but wrong sha256 refused" bash "$here/import.sh" final "$t/wh"
mk "$t/jl" final no plain; echo 'this is not a checksum line' >> "$t/jl/MANIFEST"
expect_msg 1 "malformed MANIFEST" "a line the checker cannot parse is refused (--strict)" bash "$here/import.sh" final "$t/jl"
mk "$t/mh" final no plain
sed 's/^[0-9a-f]\{64\}  openclaw-backup/deadbeef  openclaw-backup/' "$t/mh/MANIFEST" > "$t/mh/M" && mv "$t/mh/M" "$t/mh/MANIFEST"
expect 1 "malformed hash for a listed file refused" bash "$here/import.sh" final "$t/mh"
mk "$t/uc" final no plain
awk '{ if ($2 == "filestate.tar.gz") $1 = toupper($1); print $1 (NF > 1 ? "  " $2 : "") }' "$t/uc/MANIFEST" > "$t/uc/M" && mv "$t/uc/M" "$t/uc/MANIFEST"
expect_msg 1 "64-hex" "MANIFEST hashes must be 64 lowercase hex, as export.sh writes them" bash "$here/import.sh" final "$t/uc"
mk "$t/nf" final no plain
grep -v 'filestate.tar.gz' "$t/nf/MANIFEST" > "$t/nf/M" && mv "$t/nf/M" "$t/nf/MANIFEST"
expect_msg 1 "does not list filestate.tar.gz" "MANIFEST missing a file entry refused" bash "$here/import.sh" final "$t/nf"

# Unreadable archives whose MANIFEST matches them: only the tar-readable check can refuse these with
# the named message (a bare set -e exit would carry tar's own status and no explanation).
mk "$t/ub" final no plain; echo 'not a gzip' > "$t/ub/openclaw-backup.tar.gz"; manifest "$t/ub" final
expect_msg 1 "cannot read .*openclaw-backup" "unreadable backup archive refused with a message" bash "$here/import.sh" final "$t/ub"
mk "$t/uf" final no plain; echo 'not a gzip' > "$t/uf/filestate.tar.gz"; manifest "$t/uf" final
expect_msg 1 "cannot read .*filestate" "unreadable file-state archive refused with a message" bash "$here/import.sh" final "$t/uf"

mkdir -p "$t/home/.openclaw" && touch "$t/home/.openclaw/openclaw.json"
expect 1 "existing state refused without --force"  bash "$here/import.sh" final "$t/fin"
expect 0 "existing state accepted with --force"    bash "$here/import.sh" final "$t/fin" --force
rm -rf "$t/home/.openclaw"
expect 0 "drill accepts a final archive (credentials stripped after restore)" bash "$here/import.sh" drill "$t/fin"
expect 0 "drill accepts a rehearsal archive"       bash "$here/import.sh" drill "$t/reh"

# ===== Part 2: a real import against fake tools ===================================================
mkdir -p "$t/bin"
cat > "$t/bin/openclaw" <<'EOF'
#!/bin/bash
# Fake openclaw: logs every call with whether the bootstrap token was in its environment, and for a config write how
# many openclaw.json backups sit where OpenClaw rotates them (a real write rotates .bak*).
H="$IMPORT_HOME"
echo "openclaw $* | token=${OP_SERVICE_ACCOUNT_TOKEN:+set}" >> "$FAKE_LOG"
case "$1 $2" in "config set"|"config unset")
  echo "config-write backups=$(find "$H/.openclaw" -maxdepth 1 \( -name openclaw.json.last-good -o -name 'openclaw.json.bak*' -o -name 'openclaw.json.pre-*' -o -name 'openclaw.json.clobbered.*' \) 2>/dev/null | wc -l | tr -d ' ')" >> "$FAKE_LOG" ;;
esac
# FAKE_ROTATE: a config write rotates .bak -> .bak.1 ... .bak.4 and copies the current config to .bak, as OpenClaw does.
case "$1 $2" in "config set"|"config unset")
  if [ -n "${FAKE_ROTATE:-}" ] && [ -f "$H/.openclaw/openclaw.json" ]; then
    c="$H/.openclaw/openclaw.json"; i=3
    while [ "$i" -ge 1 ]; do [ -e "$c.bak.$i" ] && mv "$c.bak.$i" "$c.bak.$((i + 1))"; i=$((i - 1)); done
    [ -e "$c.bak" ] && mv "$c.bak" "$c.bak.1"
    cp "$c" "$c.bak"
  fi ;;
esac
case "$1 $2" in
  "backup restore")
    # The archive's original home decides the layout (FAKE_ARCHIVE_HOME; default: the importing home).
    root="$5/2026-01-01T00-00-00-openclaw-backup/payload/posix${FAKE_ARCHIVE_HOME:-$H}"
    mkdir -p "$root"
    # "layout" is the listing-only member that tells import.sh the archive's home at validation time.
    if [ -z "${FAKE_RESTORE_NONE:-}" ]; then tar -xzf "$3" -C "$root" --exclude layout; fi
    if [ -n "${FAKE_RESTORE_TWICE:-}" ]; then mkdir -p "$5/2026-01-01T00-00-00-openclaw-backup/payload/posix/srv/other/.openclaw"; fi ;;
  "config set")
    if [ "$3" = cron.enabled ]; then touch "$H/.openclaw/cron-off"; fi ;;
  "config unset")
    if [ -n "${FAKE_UNSET_MSG:-}" ]; then echo "$FAKE_UNSET_MSG"; exit 1; fi ;;
  "gateway install")
    echo "install: wa=$(find "$H/.openclaw/credentials" "$H"/.openclaw-stale-*/credentials "$H/.wacli" \( -name 'whatsapp*' -o -name 'session.db*' \) 2>/dev/null | wc -l | tr -d ' ') cron_off=$([ -e "$H/.openclaw/cron-off" ] && echo yes || echo no)" >> "$FAKE_LOG" ;;
  "doctor --fix")
    if [ -n "${FAKE_DOCTOR_LEAK:-}" ]; then echo '{"p":"/Users/admin/brain"}' > "$H/.openclaw/cron/leak.json"; fi ;;
  "automations list") echo '{"jobs":[]}' ;;
esac
exit 0
EOF
cat > "$t/bin/systemctl" <<'EOF'
#!/bin/bash
# Fake systemctl. is-active prints the state and exits non-zero for every state but active, as the real one does;
# --quiet prints nothing, so an "activating" unit looks like a plain failure to it.
echo "systemctl $*" >> "$FAKE_LOG"
case "$*" in
  "--user show-environment") [ -z "${FAKE_NO_MANAGER:-}" ] || { echo "Failed to connect to bus: No medium found" >&2; exit 1; } ;;
  "--user is-active --quiet "*) [ "$4" = "${FAKE_ACTIVE_UNIT:-none}" ] && exit 0; exit 3 ;;
  "--user is-active "*)
    if [ "$3" = "${FAKE_ACTIVE_UNIT:-none}" ]; then echo active; exit 0; fi
    if [ "$3" = "${FAKE_ACTIVATING_UNIT:-none}" ]; then echo activating; exit 3; fi
    if [ "$3" = "${FAKE_FAILED_UNIT:-none}" ]; then echo failed; exit 3; fi
    echo inactive; exit 3 ;;
  "--user cat "*) echo "[Service]" ;;
esac
exit 0
EOF
cat > "$t/bin/mv" <<'EOF'
#!/bin/bash
# Fake mv: a real mv, then (for the move of the restored tree into place) a count of WhatsApp entries now
# live under HOME and, on request, a crash right after the move.
/bin/mv "$@" || exit $?
dest="${!#}"
if [ "$dest" = "$IMPORT_HOME/.openclaw" ]; then
  echo "mv-into-place wa=$(find "$dest/credentials" -name 'whatsapp*' 2>/dev/null | wc -l | tr -d ' ')" >> "$FAKE_LOG"
  if [ -n "${FAKE_DIE_AFTER_MOVE:-}" ]; then echo "mv: simulated crash right after the move into place" >&2; exit 1; fi
fi
exit 0
EOF
cat > "$t/bin/npm" <<'EOF'
#!/bin/bash
H="$IMPORT_HOME"
echo "npm $* oldhome=$(grep -rlE '/Users/admin([^a-z0-9]|$)' "$H/.openclaw/openclaw.json" "$H/.openclaw/cron" "$H/brain" "$H/ops" "$H/.ssh" 2>/dev/null | wc -l | tr -d ' ') token=${OP_SERVICE_ACCOUNT_TOKEN:+set} cron_off=$([ -e "$H/.openclaw/cron-off" ] && echo yes || echo no) wa=$(find "$H/.openclaw/credentials" "$H"/.openclaw-stale-*/credentials "$H/.wacli" \( -name 'whatsapp*' -o -name 'session.db*' \) 2>/dev/null | wc -l | tr -d ' ')" >> "$FAKE_LOG"
[ -z "${FAKE_NPM_FAIL:-}" ] || { echo "npm: simulated failure" >&2; exit 1; }
exit 0
EOF
printf '#!/bin/bash\necho fake-gateway-token\n' > "$t/bin/op"
cat > "$t/bin/tailscale" <<'EOF'
#!/bin/bash
echo "tailscale $*" >> "$FAKE_LOG"
if [ "$1 ${2:-}" = "debug prefs" ] && [ -n "${FAKE_TS_PREFS_FAIL:-}" ]; then exit 1; fi
if [ "$1 ${2:-}" = "debug prefs" ] && [ -n "${FAKE_TS_PREFS_BAD:-}" ]; then echo "this is not json"; exit 0; fi
if [ "$1 ${2:-}" = "debug prefs" ]; then echo "{\"OperatorUser\":\"${FAKE_TS_OPERATOR-$(id -un)}\"}"; exit 0; fi
echo "{\"BackendState\":\"${FAKE_TS_STATE:-NeedsLogin}\"}"
EOF
printf '#!/bin/bash\necho "timeout $1" >> "$FAKE_LOG"\nshift\nexec "$@"\n' > "$t/bin/timeout"
cat > "$t/bin/date" <<'EOF'
#!/bin/bash
if [ -n "${FAKE_DATE:-}" ] && [ "${2:-}" = "+%Y%m%dT%H%M%SZ" ]; then echo "$FAKE_DATE"; exit 0; fi
exec /bin/date "$@"
EOF
FAKE_REAL_TAR_DEFAULT=$(command -v tar); export FAKE_REAL_TAR_DEFAULT
cat > "$t/bin/tar" <<'EOF'
#!/bin/bash
# Fake tar: the real one (FAKE_REAL_TAR picks which), except that the member-list extraction can be made to fail, or
# to leave things behind in .ssh once the real tar has returned (FAKE_TAR_PLANT words: ak, x and akdir plant an
# authorized_keys file, an id_x and an authorized_keys directory; links turns config and known_hosts into symlinks;
# khdir turns known_hosts into a directory; sshlink, after any file-state extraction, turns .ssh itself into a symlink
# to the directory $IMPORT_HOME.target).
# FAKE_TAR_VEXTRA adds one line to a verbose listing.
if [ -n "${FAKE_TAR_FAIL:-}" ]; then case " $* " in *" -T "*) echo "tar: simulated failure" >&2; exit 2 ;; esac; fi
"${FAKE_REAL_TAR:-$FAKE_REAL_TAR_DEFAULT}" "$@"; rc=$?
if [ -n "${FAKE_TAR_VEXTRA:-}" ]; then case " $* " in *" -tvzf "*) echo "-rw-r--r-- 0 x x 0 Jan  1 00:00 extra" ;; esac; fi
if [ -n "${FAKE_TAR_PLANT:-}" ]; then
  case " $* " in *" -T "*)
    mkdir -p "$IMPORT_HOME/.ssh"
    case " $FAKE_TAR_PLANT " in *" ak "*) echo planted > "$IMPORT_HOME/.ssh/authorized_keys" ;; esac
    case " $FAKE_TAR_PLANT " in *" x "*) echo planted > "$IMPORT_HOME/.ssh/id_x" ;; esac
    case " $FAKE_TAR_PLANT " in *" akdir "*) mkdir -p "$IMPORT_HOME/.ssh/authorized_keys"; echo planted > "$IMPORT_HOME/.ssh/authorized_keys/k" ;; esac
    case " $FAKE_TAR_PLANT " in *" links "*) ln -sf authorized_keys "$IMPORT_HOME/.ssh/config"; ln -sf authorized_keys "$IMPORT_HOME/.ssh/known_hosts" ;; esac
    case " $FAKE_TAR_PLANT " in *" khdir "*) rm -f "$IMPORT_HOME/.ssh/known_hosts"; mkdir -p "$IMPORT_HOME/.ssh/known_hosts"; echo planted > "$IMPORT_HOME/.ssh/known_hosts/k" ;; esac ;;
  esac
  case " $FAKE_TAR_PLANT " in *" sshlink "*)
    case " $* " in *" -xzf "*"/filestate.tar.gz "*) rm -rf "$IMPORT_HOME/.ssh"; ln -s "$IMPORT_HOME.target" "$IMPORT_HOME/.ssh" ;; esac ;;
  esac
fi
exit $rc
EOF
cat > "$t/bin/id" <<'EOF'
#!/bin/bash
if [ "$*" = "-u" ] && [ -n "${FAKE_UID:-}" ]; then echo "$FAKE_UID"; exit 0; fi
exec /usr/bin/id "$@"
EOF
cat > "$t/bin/python3" <<'EOF'
#!/bin/bash
# Fake python3 (the state-path migration; migrate/state-paths.test.py tests the real one): logs its arguments and
# whether the restored state has landed, then exits FAKE_PY_RC (default 0).
echo "python3 $* | landed=$([ -f "$IMPORT_HOME/.openclaw/openclaw.json" ] && echo yes || echo no)" >> "$FAKE_LOG"
if [ -n "${FAKE_PY_RC:-}" ]; then echo "state-paths: refused: simulated" >&2; exit "$FAKE_PY_RC"; fi
exit 0
EOF
chmod +x "$t/bin/"*

mkfull() { # mkfull <dir> <label> [notoken|badtoken|nltoken|quotedtoken]: a restore-shaped export, final-style (live WhatsApp state in it)
  local d="$1" s="$1/src"
  mkdir -p "$d" "$s/.openclaw/credentials/whatsapp/default" "$s/.openclaw/credentials/whatsapp.backup.1"
  if [ -n "${FIX_TS_MODE:-}" ]; then printf '{"gateway":{"tailscale":{"mode":"%s"}}}\n' "$FIX_TS_MODE" > "$s/.openclaw/openclaw.json"; else echo '{}' > "$s/.openclaw/openclaw.json"; fi
  echo '{}' > "$s/.openclaw/credentials/whatsapp/default/creds.json"
  echo '{}' > "$s/.openclaw/credentials/whatsapp.backup.1/creds.json"
  echo '[]' > "$s/.openclaw/credentials/whatsapp-allowFrom.json"   # legacy per-channel file, not a directory
  echo '{}' > "$s/.openclaw/credentials/other-pairing.json"
  tar -C "$s" -czf "$d/openclaw-backup.tar.gz" .openclaw
  rm -rf "$s"
  mkdir -p "$s/.openclaw/service-env" "$s/brain/harvester" "$s/.wacli" "$s/.ssh" "$s/.openclaw-stale-1/credentials/whatsapp/default"
  if [ "${3:-}" = notoken ]; then printf 'export HOME=/x\n' > "$s/.openclaw/service-env/ai.openclaw.gateway.env"
  elif [ "${3:-}" = badtoken ]; then printf 'export HOME=/x\nexport OP_SERVICE_ACCOUNT_TOKEN=%s\n' "'abc;touch def'" > "$s/.openclaw/service-env/ai.openclaw.gateway.env"
  elif [ "${3:-}" = nltoken ]; then printf 'export HOME=/x\nexport OP_SERVICE_ACCOUNT_TOKEN=%s\n' "\$'abc\\nfoo'" > "$s/.openclaw/service-env/ai.openclaw.gateway.env"
  elif [ "${3:-}" = quotedtoken ]; then printf 'export HOME=/x\nexport OP_SERVICE_ACCOUNT_TOKEN=%s\n' "\"'abc'\"" > "$s/.openclaw/service-env/ai.openclaw.gateway.env"
  else printf 'export HOME=/x\nexport OP_SERVICE_ACCOUNT_TOKEN=fixture_bootstrap_value\n' > "$s/.openclaw/service-env/ai.openclaw.gateway.env"; fi
  echo '{}' > "$s/brain/harvester/package-lock.json"
  echo x > "$s/.wacli/session.db"; echo y > "$s/.wacli/messages.db"
  echo 'ssh-ed25519 AAAAfixture fixture' > "$s/.ssh/authorized_keys"
  echo '{}' > "$s/.openclaw-stale-1/credentials/whatsapp/default/creds.json"
  echo keep > "$s/.openclaw-stale-1/credentials/keep.txt"
  local extra=()
  if [ -n "${FIX_OPS:-}" ]; then
    mkdir -p "$s/ops/listener-guard" "$s/ops/bench"
    for f in listener-guard.mjs launchd.out.log launchd.err.log; do echo "launchctl kickstart" > "$s/ops/listener-guard/$f"; done
    echo keep > "$s/ops/bench/run.sh"; extra=(ops)
  fi
  tar -C "$s" -czf "$d/filestate.tar.gz" brain .wacli .ssh .openclaw-stale-1 .openclaw/service-env/ai.openclaw.gateway.env ${extra[@]+"${extra[@]}"}
  rm -rf "$s"
  manifest "$d" "$2"
}
mknight() { # mknight <dir> <dotenv-content> [both]: a Linux nightly: ~/.openclaw/.env in the filestate, no service-env ("both" adds the macOS file too)
  local d="$1" s="$1/src" members=(brain .wacli .ssh .openclaw/.env)
  mkdir -p "$d" "$s/.openclaw/credentials/whatsapp/default"
  echo '{}' > "$s/.openclaw/openclaw.json"
  echo '{}' > "$s/.openclaw/credentials/whatsapp/default/creds.json"
  tar -C "$s" -czf "$d/openclaw-backup.tar.gz" .openclaw
  rm -rf "$s"
  mkdir -p "$s/.openclaw" "$s/brain/harvester" "$s/.wacli" "$s/.ssh"
  printf '%s\n' "$2" > "$s/.openclaw/.env"
  if [ "${3:-}" = both ]; then
    mkdir -p "$s/.openclaw/service-env"
    printf 'export OP_SERVICE_ACCOUNT_TOKEN=macos_file_value\n' > "$s/.openclaw/service-env/ai.openclaw.gateway.env"
    members+=(.openclaw/service-env/ai.openclaw.gateway.env)
  fi
  echo '{}' > "$s/brain/harvester/package-lock.json"
  echo x > "$s/.wacli/session.db"
  echo 'ssh-ed25519 AAAAfixture fixture' > "$s/.ssh/authorized_keys"
  tar -C "$s" -czf "$d/filestate.tar.gz" "${members[@]}"
  rm -rf "$s"
  manifest "$d" nightly
}
fresh() { rm -rf "${t:?}/home" "${t:?}/ev"; mkdir -p "$t/home"; : > "$t/ev"; unset FAKE_NPM_FAIL FAKE_ACTIVE_UNIT FAKE_ACTIVATING_UNIT FAKE_FAILED_UNIT FAKE_UNSET_MSG FAKE_DATE FAKE_DIE_AFTER_MOVE FAKE_TS_STATE FAKE_ARCHIVE_HOME FAKE_RESTORE_TWICE FAKE_NO_MANAGER FAKE_UID FAKE_TS_OPERATOR FAKE_RESTORE_NONE FAKE_DOCTOR_LEAK FAKE_TS_PREFS_FAIL FAKE_TS_PREFS_BAD FAKE_TAR_FAIL FAKE_TAR_PLANT FAKE_TAR_VEXTRA FAKE_PY_RC || true; }
run_import() { env IMPORT_DRY=0 FAKE_LOG="$t/ev" PATH="$t/bin:$PATH" bash "$here/import.sh" "$@"; }
no_wa_files() { [ -z "$(find "$t/home/.openclaw/credentials" "$t/home"/.openclaw-stale-*/credentials "$t/home/.wacli" \( -name 'whatsapp*' -o -name 'session.db*' \) 2>/dev/null)" ]; }
ev() { grep -Eq -- "$1" "$t/ev"; }
in_order() { # in_order <ere>...: the first event matching each pattern comes after the first matching the one before
  local prev=0 n pat
  for pat in "$@"; do
    n=$(grep -nE -- "$pat" "$t/ev" | head -1 | cut -d: -f1)
    if [ -z "$n" ] || [ "$n" -le "$prev" ]; then return 1; fi
    prev=$n
  done
}

mkfull "$t/full" final

# A drill of a final archive: every WhatsApp file is gone from $HOME before the gateway can start, the
# legacy credentials/whatsapp-allowFrom.json included, and unrelated files survive.
fresh
export OP_SERVICE_ACCOUNT_TOKEN=inherited_value   # in the caller's environment: npm ci must still not see a token
expect 0 "drill of a final archive completes against fake tools" run_import drill "$t/full"
unset OP_SERVICE_ACCOUNT_TOKEN
check "the token carried over is the archive's, not the caller's" grep -q '^OP_SERVICE_ACCOUNT_TOKEN=fixture_bootstrap_value$' "$t/home/.openclaw/.env"
check "nothing armed is live under HOME right after the move into place" ev '^mv-into-place wa=0$'
check "drill leaves no WhatsApp credential, backup copy or wacli session under HOME" no_wa_files
check "drill strips credentials/whatsapp* including legacy whatsapp-allowFrom.json" test ! -e "$t/home/.openclaw/credentials/whatsapp-allowFrom.json"
check "drill keeps unrelated credentials files" test -f "$t/home/.openclaw/credentials/other-pairing.json"
check "drill keeps the rest of the wacli store" test -f "$t/home/.wacli/messages.db"
check "drill strips WhatsApp credentials inside a carried .openclaw-stale-* dir, keeps the rest" \
  bash -c '[ ! -e "$1/.openclaw-stale-1/credentials/whatsapp" ] && [ -f "$1/.openclaw-stale-1/credentials/keep.txt" ]' _ "$t/home"
check "strip and cron-off precede the gateway install" ev '^install: wa=0 cron_off=yes$'
check "cron is off before npm ci and npm ci sees no token and no credentials" ev '^npm ci .* token= cron_off=yes wa=0$'
check "the token reaches openclaw only after npm ci" ev 'config set plugins.entries.imessage.enabled false \| token=set'
check "guard timer, guard service, then gateway are disabled and proven inactive, all before the restore and the state landing" \
  in_order 'disable --now openclaw-listener-guard\.timer$' 'disable --now openclaw-listener-guard\.service$' \
  'disable --now openclaw-gateway\.service$' 'is-active openclaw-gateway\.service$' 'backup restore' 'config set cron\.enabled false'
check "the health poll wraps each call in timeout 10" ev '^timeout 10$'

# A final import installs the nightly backup: the script, the token parser it sources from ../lib, and the units.
fresh
expect 0 "a final import of a final archive completes against fake tools" run_import final "$t/full"
check "final mode installs the nightly script and the token parser it needs, side by side" \
  bash -c '[ -f "$1/ops/backup/nightly-backup.sh" ] && [ -f "$1/ops/lib/dotenv-token.sh" ] && cmp -s "$1/ops/lib/dotenv-token.sh" "$2/ops/lib/dotenv-token.sh"' _ "$t/home" "$here/.."
check "final mode installs the backup-health check next to the nightly script" \
  bash -c '[ -f "$1/ops/backup/backup-health.mjs" ] && cmp -s "$1/ops/backup/backup-health.mjs" "$2/ops/backup/backup-health.mjs"' _ "$t/home" "$here/.."
check "final mode installs both nightly units" \
  bash -c '[ -f "$1/.config/systemd/user/openclaw-nightly-backup.service" ] && [ -f "$1/.config/systemd/user/openclaw-nightly-backup.timer" ]' _ "$t/home"
check "final mode enables the nightly timer" ev 'enable --now openclaw-nightly-backup\.timer$'
fresh
expect 0 "a drill installs no nightly backup" run_import drill "$t/full"
check "a drill leaves out the nightly script, the health check, its parser and its timer" \
  bash -c '[ ! -e "$1/ops/backup/backup-health.mjs" ] && [ ! -e "$1/ops/backup" ] && [ ! -e "$1/ops/lib" ] && ! grep -q "openclaw-nightly-backup" "$2"' _ "$t/home" "$t/ev"

# Partial failure (npm ci, the network): nothing armed is left behind and cron is already off.
fresh
export FAKE_NPM_FAIL=1
expect 1 "a failing npm ci aborts the drill" run_import drill "$t/full"
check "after a failed drill no WhatsApp file is under HOME" no_wa_files
check "after a failed drill cron is already disabled" test -e "$t/home/.openclaw/cron-off"
check "a failed drill never reached gateway install" bash -c '! grep -q "gateway install" "$1"' _ "$t/ev"
unset FAKE_NPM_FAIL

# A unit that will not stop: refuse before touching the state.
fresh; mkdir -p "$t/home/.openclaw"; echo old-state > "$t/home/.openclaw/openclaw.json"
export FAKE_ACTIVE_UNIT=openclaw-gateway.service
expect_msg 1 "is 'active' after disable" "a gateway that stays active refuses the import" run_import drill "$t/full" --force
check "the existing state was not touched" test "$(cat "$t/home/.openclaw/openclaw.json")" = old-state
check "no restore was attempted" bash -c '! grep -q "backup restore" "$1"' _ "$t/ev"
unset FAKE_ACTIVE_UNIT
# A unit still starting (a guard run that just restarted the gateway) is not inactive either.
fresh; mkdir -p "$t/home/.openclaw"; echo old-state > "$t/home/.openclaw/openclaw.json"
export FAKE_ACTIVATING_UNIT=openclaw-gateway.service
expect_msg 1 "is 'activating' after disable" "a gateway that is still activating refuses the import" run_import drill "$t/full" --force
check "the state was not touched while the gateway was activating" test "$(cat "$t/home/.openclaw/openclaw.json")" = old-state
unset FAKE_ACTIVATING_UNIT
fresh; mkdir -p "$t/home/.openclaw"; echo old-state > "$t/home/.openclaw/openclaw.json"
export FAKE_ACTIVATING_UNIT=openclaw-listener-guard.service
expect_msg 1 "openclaw-listener-guard.service is 'activating'" "a guard unit that is still activating refuses the import" run_import drill "$t/full" --force
unset FAKE_ACTIVATING_UNIT
# A unit left in the failed state (a crash-looping gateway that hit its start limit) is stopped: allowed.
fresh; export FAKE_FAILED_UNIT=openclaw-gateway.service
expect 0 "a gateway left in the failed state does not block the import" run_import drill "$t/full"
unset FAKE_FAILED_UNIT

# A crash right after the restored tree lands: nothing armed may be under HOME (the strip happens in the stage).
fresh; export FAKE_DIE_AFTER_MOVE=1
expect_msg 1 "simulated crash right after the move" "a crash right after the move into place aborts the drill" run_import drill "$t/full"
check "the restored state did land" test -d "$t/home/.openclaw"
check "no WhatsApp file was ever live under HOME after that crash" no_wa_files
check "the WhatsApp entries counted at the moment of the move were zero" ev '^mv-into-place wa=0$'
unset FAKE_DIE_AFTER_MOVE

# --force moves the old state aside, for real this time (Part 1 exits before the move).
fresh; mkdir -p "$t/home/.openclaw"; echo old-state > "$t/home/.openclaw/openclaw.json"
expect 0 "drill --force over existing state completes" run_import drill "$t/full" --force
check "the old state was moved aside intact" bash -c 'set -- "$1"/.openclaw.pre-import-*; [ $# -eq 1 ] && [ "$(cat "$1/openclaw.json")" = old-state ]' _ "$t/home"
check "the restored state is in place" test "$(cat "$t/home/.openclaw/openclaw.json")" = '{}'

# An aside name that already exists must not swallow the old state (mv into a directory nests).
fresh; mkdir -p "$t/home/.openclaw" "$t/home/.openclaw.pre-import-20260101T000000Z"; echo old-state > "$t/home/.openclaw/openclaw.json"
export FAKE_DATE=20260101T000000Z
expect_msg 1 "already exists" "an existing aside dir is refused" run_import drill "$t/full" --force
check "the old state is still in place, not nested in the aside dir" \
  bash -c '[ "$(cat "$1/.openclaw/openclaw.json")" = old-state ] && [ ! -e "$1/.openclaw.pre-import-20260101T000000Z/.openclaw" ]' _ "$t/home"
unset FAKE_DATE

# A session or credential copy already on the box is not deleted silently, and not started on.
fresh; mkdir -p "$t/home/.wacli"; echo live > "$t/home/.wacli/session.db"
expect_msg 1 "are present under" "a wacli session already on the box stops the drill" run_import drill "$t/full"
check "that session was left alone" test "$(cat "$t/home/.wacli/session.db")" = live

# The bootstrap token comes from the archive, never from the caller's environment.
fresh; mkfull "$t/notok" final notoken
export OP_SERVICE_ACCOUNT_TOKEN=inherited_value
expect_msg 1 "bootstrap token missing" "an inherited token cannot stand in for a missing one" run_import drill "$t/notok"
unset OP_SERVICE_ACCOUNT_TOKEN
check "a refused import touched nothing" test ! -e "$t/home/.openclaw"
# The macOS file's token goes through the same shared parser as a dotenv token.
fresh; mkfull "$t/badtok" final badtoken
expect_msg 1 "characters a dotenv file cannot carry" "a macOS env file whose token has shell metacharacters and whitespace is refused" run_import drill "$t/badtok"
check "that refused import touched nothing either" test ! -e "$t/home/.openclaw"
# The value is checked as the file set it: wrapped into a dotenv line and re-parsed, a newline would drop the
# rest of the value and literal quotes would be stripped, so the import would carry a different token.
fresh; mkfull "$t/nltok" final nltoken
expect_msg 1 "characters a dotenv file cannot carry" "a macOS env file whose token contains a newline is refused, not cut at it" run_import drill "$t/nltok"
check "that refused import touched nothing (newline)" test ! -e "$t/home/.openclaw"
fresh; mkfull "$t/qtok" final quotedtoken
expect_msg 1 "characters a dotenv file cannot carry" "a macOS env file whose token has literal surrounding quotes is refused, not unquoted" run_import drill "$t/qtok"
check "that refused import touched nothing (quotes)" test ! -e "$t/home/.openclaw"
# The shared parser is part of the repo checkout: without it the import refuses before touching anything.
mkdir -p "$t/norepo/migrate" "$t/norepo/ops/listener-guard"
cp "$here/import.sh" "$t/norepo/migrate/"; : > "$t/norepo/ops/listener-guard/guard.mjs"
fresh
expect_msg 1 "ops/lib/dotenv-token.sh missing from the repo checkout" "a repo checkout without the shared token parser is refused" env IMPORT_DRY=0 FAKE_LOG="$t/ev" PATH="$t/bin:$PATH" bash "$t/norepo/migrate/import.sh" drill "$t/full"
check "that refused import touched nothing" test ! -e "$t/home/.openclaw"

# A Linux nightly carries the token in ~/.openclaw/.env (the CLI and service load it themselves), not in
# the macOS service-env file. import.sh must read it, and only read it: a dotenv is data, never code.
fresh; mknight "$t/night" $'OTHER=1\nOP_SERVICE_ACCOUNT_TOKEN=nightly_bootstrap_value'
expect 0 "drill accepts a nightly-shaped archive whose token member is the .env" run_import drill "$t/night"
check "the token parsed from the nightly's .env is carried over" grep -q '^OP_SERVICE_ACCOUNT_TOKEN=nightly_bootstrap_value$' "$t/home/.openclaw/.env"
check "the parsed token reaches openclaw, and only after npm ci" bash -c 'grep -q "^npm ci .* token= " "$1" && grep -q "config set plugins.entries.imessage.enabled false | token=set" "$1"' _ "$t/ev"
check "other lines of the nightly's .env survive" grep -q '^OTHER=1$' "$t/home/.openclaw/.env"

fresh; rm -f "$t/pwned"
evil=$(printf '%s\n' 'OP_SERVICE_ACCOUNT_TOKEN=nightly_bootstrap_value' "X=\$(touch $t/pwned)" "touch $t/pwned" "\`touch $t/pwned\`" "; touch $t/pwned")
mknight "$t/evil" "$evil"
expect 0 "a nightly .env with shell metacharacters on other lines is still imported" run_import drill "$t/evil"
check "no line of the .env was executed" test ! -e "$t/pwned"
check "the token is still the parsed one" grep -q '^OP_SERVICE_ACCOUNT_TOKEN=nightly_bootstrap_value$' "$t/home/.openclaw/.env"

fresh; rm -f "$t/pwned"; mknight "$t/evtok" "OP_SERVICE_ACCOUNT_TOKEN=abc;touch\${IFS}$t/pwned"
expect_msg 1 "characters a dotenv file cannot carry" "a .env token with shell metacharacters is refused by the format check" run_import drill "$t/evtok"
check "that token was not executed either" test ! -e "$t/pwned"

fresh; mknight "$t/dq" 'OP_SERVICE_ACCOUNT_TOKEN="double_quoted_value"'
expect 0 "a double-quoted .env token is accepted" run_import drill "$t/dq"
check "surrounding double quotes are stripped" grep -q '^OP_SERVICE_ACCOUNT_TOKEN=double_quoted_value$' "$t/home/.openclaw/.env"
fresh; mknight "$t/sq" "OP_SERVICE_ACCOUNT_TOKEN='single_quoted_value'"
expect 0 "a single-quoted .env token is accepted" run_import drill "$t/sq"
check "surrounding single quotes are stripped" grep -q '^OP_SERVICE_ACCOUNT_TOKEN=single_quoted_value$' "$t/home/.openclaw/.env"

# One parser for the token (ops/lib/dotenv-token.sh, shared with the nightly backup), stricter than any
# loader: whatever a loader could read differently is refused, never guessed.
refuses_token() { # refuses_token <name> <message-regex> <dotenv content>
  fresh; mknight "$t/rt-$1" "$3"
  expect_msg 1 "$2" "a .env with $1 is refused" run_import drill "$t/rt-$1"
  check "  ... and that refused import touched nothing ($1)" test ! -e "$t/home/.openclaw"
}
refuses_token crlf "CRLF" $'OP_SERVICE_ACCOUNT_TOKEN=abc\r'
refuses_token crlf-elsewhere "CRLF" $'OTHER=1\r\nOP_SERVICE_ACCOUNT_TOKEN=abc'
refuses_token dup "set 2 times" $'OP_SERVICE_ACCOUNT_TOKEN=aaa\nOP_SERVICE_ACCOUNT_TOKEN=bbb'
refuses_token export-dup "set 2 times" $'OP_SERVICE_ACCOUNT_TOKEN=aaa\nexport OP_SERVICE_ACCOUNT_TOKEN=bbb'
refuses_token indented-dup "set 2 times" $'OP_SERVICE_ACCOUNT_TOKEN=aaa\n  OP_SERVICE_ACCOUNT_TOKEN=bbb'
refuses_token prefix-only-key "bootstrap token missing" 'OP_SERVICE_ACCOUNT_TOKEN_OLD=abc'
refuses_token empty-value "value is empty" 'OP_SERVICE_ACCOUNT_TOKEN='
refuses_token empty-quoted-value "value is empty" 'OP_SERVICE_ACCOUNT_TOKEN=""'
refuses_token inline-comment "contains '#'" 'OP_SERVICE_ACCOUNT_TOKEN=abc # the old one'
refuses_token whitespace "contains whitespace" 'OP_SERVICE_ACCOUNT_TOKEN=abc def'
key_lines() { grep -Ec '^[[:space:]]*(export[[:space:]]+)?OP_SERVICE_ACCOUNT_TOKEN[[:space:]]*=' "$1"; }
accepts_token() { # accepts_token <name> <dotenv content> <token>: accepted, and the restored .env ends with that one assignment
  fresh; mknight "$t/at-$1" "$2"
  expect 0 "a .env with $1 is accepted" run_import drill "$t/at-$1"
  check "  ... and carries exactly one assignment, the parsed token ($1)" \
    bash -c '[ "$("$1" "$2")" = 1 ] && grep -q "^OP_SERVICE_ACCOUNT_TOKEN=$3\$" "$2"' _ key_lines "$t/home/.openclaw/.env" "$3"
}
export -f key_lines
accepts_token export-prefix 'export OP_SERVICE_ACCOUNT_TOKEN=from_export' from_export
accepts_token indented-key '   OP_SERVICE_ACCOUNT_TOKEN=from_indented' from_indented
accepts_token commented-out-line $'# OP_SERVICE_ACCOUNT_TOKEN=old_value\nOP_SERVICE_ACCOUNT_TOKEN=from_live_line' from_live_line
accepts_token prefix-named-key-too $'OP_SERVICE_ACCOUNT_TOKEN_OLD=old_value\nOP_SERVICE_ACCOUNT_TOKEN=from_real_key' from_real_key
check "the key that only prefix-matches is kept untouched" grep -q '^OP_SERVICE_ACCOUNT_TOKEN_OLD=old_value$' "$t/home/.openclaw/.env"

fresh; mknight "$t/notokn" 'OTHER=1'
export OP_SERVICE_ACCOUNT_TOKEN=inherited_value
expect_msg 1 "bootstrap token missing" "a .env without the token line is refused, whatever the caller's environment holds" run_import drill "$t/notokn"
unset OP_SERVICE_ACCOUNT_TOKEN
check "that refused import touched nothing" test ! -e "$t/home/.openclaw"

# Both members in one archive is not something either exporter produces; the Linux .env is the source of
# truth and the only one that is never evaluated.
fresh; mknight "$t/both" 'OP_SERVICE_ACCOUNT_TOKEN=dotenv_value' both
expect 0 "an archive with both token members imports" run_import drill "$t/both"
check "the .env member wins over the macOS service-env file" grep -q '^OP_SERVICE_ACCOUNT_TOKEN=dotenv_value$' "$t/home/.openclaw/.env"

# No token member at all.
fresh; mkfull "$t/nomember" final
mkdir -p "$t/nm/brain"; echo x > "$t/nm/brain/a"
tar -C "$t/nm" -czf "$t/nomember/filestate.tar.gz" brain; manifest "$t/nomember" final
expect_msg 1 "neither .*\.env nor .*service-env" "an archive with no token member is refused with a message" run_import drill "$t/nomember"

# config unset: only the documented not-found message is tolerated.
fresh; export FAKE_UNSET_MSG='Config path not found: channels.imessage. Nothing was changed.'
expect 0 "config unset of an absent iMessage channel is tolerated" run_import drill "$t/full"
fresh; export FAKE_UNSET_MSG='Permission not found for the config file'
expect_msg 1 "config unset channels.imessage failed" "any other config unset failure aborts" run_import drill "$t/full"
unset FAKE_UNSET_MSG

# Tailscale Serve in the migrated config: a rehearsal or drill gateway must not publish itself on the tailnet,
# and a final one needs a logged-in Tailscale (the gateway does not start "Logged out").
FIX_TS_MODE=serve mkfull "$t/tsserve" final
FIX_TS_MODE=off mkfull "$t/tsoff" final
fresh
expect 0 "drill of a config with tailscale serve completes" run_import drill "$t/tsserve"
check "drill turns gateway.tailscale.mode off" ev 'config set gateway\.tailscale\.mode off'
check "tailscale mode off comes after cron-off and before the first gateway starter" \
  in_order 'config set cron\.enabled false' 'config set gateway\.tailscale\.mode off' 'gateway install'
fresh
expect 0 "drill of a config with tailscale mode off completes" run_import drill "$t/tsoff"
check "mode off: no tailscale config change and no tailscale call" bash -c '! grep -Eq "gateway\.tailscale|^tailscale" "$1"' _ "$t/ev"
fresh; export FAKE_TS_STATE=NeedsLogin
expect_msg 1 "needs a logged-in Tailscale .*NeedsLogin" "final with serve and a logged-out tailscale refuses" run_import final "$t/tsserve"
check "that refusal touched nothing" test ! -e "$t/home/.openclaw"
fresh; export FAKE_TS_STATE=Running
expect 0 "final with serve and a running tailscale proceeds" run_import final "$t/tsserve"
check "final leaves gateway.tailscale.mode alone" bash -c '! grep -q "gateway\.tailscale" "$1"' _ "$t/ev"
fresh; export FAKE_TS_STATE=NeedsLogin
expect 0 "final with tailscale mode off does not need tailscale" run_import final "$t/tsoff"
unset FAKE_TS_STATE

# The old VM's ~/ops carries the macOS listener guard; the import retires exactly those three files.
FIX_OPS=1 mkfull "$t/withops" final
for mo in drill final; do
  fresh
  expect 0 "$mo of an archive with the macOS guard completes (scan not tripped)" run_import "$mo" "$t/withops"
  check "$mo retires the macOS guard script and both launchd logs" \
    bash -c 'cd "$1/ops/listener-guard" && [ ! -e listener-guard.mjs ] && [ ! -e launchd.out.log ] && [ ! -e launchd.err.log ]' _ "$t/home"
  check "$mo logs one line per retired file" bash -c '[ "$(grep -c "retired the macOS listener guard file" "$1")" = 3 ]' _ "$t/out"
  check "$mo installs the Linux guard" test -f "$t/home/ops/listener-guard/guard.mjs"
  check "$mo leaves sibling ops files alone" test "$(cat "$t/home/ops/bench/run.sh")" = keep
done
fresh
expect 0 "an archive without the macOS guard files imports" run_import drill "$t/full"
check "no retire line when the files are absent" bash -c '! grep -q retired "$1"' _ "$t/out"

# ===== Part 2b: an archive from another home: the in-place move to the bot account (spec 2026-10-02 §2) ==========
mkold() { # mkold <dir> [flags]: a nightly made by /Users/admin whose live config names that home throughout
  # flags (words): leftover = free text names the old home; vault = the vault's git config does, in a form homepaths
  # leaves alone; guard = the Tart export's macOS guard files name it; hpfail / scanfail = a symlinked directory that
  # makes the rewrite / only the leftover scan fail; plant = extra .ssh files; home=<path> = the home the listing shows;
  # symlink / symlink2 = known_hosts (and config) link to authorized_keys; sshlink = .ssh itself is a symlink to a
  # directory in the temp tree; brainlink = an ordinary symlink elsewhere (brain/link -> notes)
  local d="$1" s="$1/src" O=/Users/admin flags=" ${2:-} " lh=/Users/admin
  case "$flags" in *" home="*) lh=${flags##* home=}; lh=${lh%% *} ;; esac
  mkdir -p "$d" "$s/.openclaw/credentials/whatsapp/default" "$s/.openclaw/cron" "$s/.openclaw/bin" \
    "$s/.openclaw/workspace/skills/s" "$s/.openclaw/agents/main/sessions"
  cat > "$s/.openclaw/openclaw.json" <<JSON
{"secrets":{"providers":{"op":{"source":"exec","command":"$O/.openclaw/bin/op-nosym","trustedDirs":["$O/.openclaw/bin","/usr/bin"]}}},
 "agents":{"defaults":{"workspace":"$O/.openclaw/workspace"},"list":[{"id":"vera","workspace":"$O/.openclaw/workspace-vera"}]},
 "plugins":{"entries":{"memory-wiki":{"config":{"vault":"$O/brain/vault"}}}},
 "notes":"/Users/administrator stays"}
JSON
  printf '{"jobs":[{"id":"j1","payload":{"kind":"command","argv":["/usr/bin/node","%s/brain/harvester/harvest.mjs"]}}]}\n' "$O" > "$s/.openclaw/cron/jobs.json"
  printf '#!/bin/sh\n# wraps op; was %s/.openclaw/bin\nexec /usr/bin/op "$@"\n' "$O" > "$s/.openclaw/bin/op-nosym"
  printf '{"dir":"%s/brain/queue"}\n' "$O" > "$s/.openclaw/workspace/skills/s/config.json"
  printf '{"role":"tool","text":"ls %s/brain"}\n' "$O" > "$s/.openclaw/agents/main/sessions/t.jsonl"
  echo '{}' > "$s/.openclaw/credentials/whatsapp/default/creds.json"
  case "$flags" in *" scanfail "*) mkdir -p "$d/real"; ln -s "$d/real" "$s/.openclaw/bin/lnk" ;; esac
  # addendum = the files the 2026-10-05 addendum moves (Codex trust, a Workshop skill, workspace scripts, memory project
  # annotations) and admin's openclaw.json backups; backupclash = a backup already in the aside dir; skillleft = a
  # Workshop skill's other file names the old home (scanned, not rewritten)
  case "$flags" in *" addendum "*)
    mkdir -p "$s/.openclaw/agents/main/agent/codex-home" "$s/.openclaw/agents/main/agent/workshop-skills/charts" \
      "$s/.openclaw/workspace/scripts" "$s/.openclaw/workspace/memory"
    printf 'model = "m"\n[projects."%s/.openclaw/workspace"]\ntrust_level = "trusted"\n' "$O" > "$s/.openclaw/agents/main/agent/codex-home/config.toml"
    printf 'Run python3 %s/.openclaw/workspace/gen_chart.py first.\n' "$O" > "$s/.openclaw/agents/main/agent/workshop-skills/charts/SKILL.md"
    printf 'OUT = "%s/.openclaw/workspace/charts"\n' "$O" > "$s/.openclaw/workspace/gen_chart.py"
    printf 'cd %s/brain && ./go\n' "$O" > "$s/.openclaw/workspace/scripts/fetch.sh"
    printf '<!-- project: path:%s/.openclaw/workspace -->\nNotes on %s/brain.\n' "$O" "$O" > "$s/.openclaw/workspace/memory/2026-09-01.md"
    printf '<!-- project: path:~/.openclaw/workspace -->\n' > "$s/.openclaw/workspace/DREAMS.md"
    for b in last-good bak bak.1 pre-update clobbered.20260901T000000Z; do
      printf '{"agents":{"defaults":{"workspace":"%s/.openclaw/workspace"}},"was":"%s"}\n' "$O" "$b" > "$s/.openclaw/openclaw.json.$b"
    done ;;
  esac
  case "$flags" in *" backupclash "*) mkdir -p "$s/.openclaw/pre-rehome-config-backups"; echo earlier > "$s/.openclaw/pre-rehome-config-backups/openclaw.json.bak" ;; esac
  case "$flags" in *" skillleft "*) mkdir -p "$s/.openclaw/agents/main/agent/workshop-skills/charts"; printf 'see %s/brain\n' "$O" > "$s/.openclaw/agents/main/agent/workshop-skills/charts/notes.txt" ;; esac
  mkdir -p "$d/lay/layout/payload/posix$lh/.openclaw"
  tar -C "$s" -czf "$d/openclaw-backup.tar.gz" .openclaw -C "$d/lay" layout
  rm -rf "$s" "$d/lay"
  mkdir -p "$s/.openclaw" "$s/brain/harvester" "$s/brain/prompts" "$s/.wacli" "$s/.ssh" "$s/ops/bench"
  printf 'OP_SERVICE_ACCOUNT_TOKEN=old_home_value\nOPENCLAW_HOME_HINT=%s/.openclaw\n' "$O" > "$s/.openclaw/.env"
  echo '{}' > "$s/brain/harvester/package-lock.json"
  printf '{"wacliBin":"/usr/local/bin/wacli","storeDb":"%s/.wacli/wacli.db"}\n' "$O" > "$s/brain/harvester/config.json"
  case "$flags" in *" vault "*) mkdir -p "$s/brain/vault/.git"; printf '[core]\n\tsshCommand = ssh -i%s/.ssh/ocsb_vault\n' "$O" > "$s/brain/vault/.git/config" ;; esac
  case "$flags" in *" guard "*) mkdir -p "$s/ops/listener-guard"; for f in listener-guard.mjs launchd.out.log launchd.err.log; do echo "$O/ops/x launchctl kickstart" > "$s/ops/listener-guard/$f"; done ;; esac
  case "$flags" in *" hpfail "*) mkdir -p "$d/real"; ln -s "$d/real" "$s/brain/lnkdir" ;; esac
  case "$flags" in *" plant "*) echo k1 > "$s/.ssh/id_ed25519"; echo k2 > "$s/.ssh/other_deploy"; echo p > "$s/.ssh/ocsb_vault.pub" ;; esac
  printf 'PATH=%s/.openclaw/bin:/usr/bin\n' "$O" > "$s/.openclaw/gateway.systemd.env"
  case "$flags" in *" leftover "*) printf 'Read %s/brain/queue first.\n' "$O" > "$s/brain/prompts/p.md" ;;
    *) echo 'Read ~/brain/queue first.' > "$s/brain/prompts/p.md" ;;
  esac
  printf '{"out":"%s/backups"}\n' "$O" > "$s/ops/bench/cfg.json"
  echo x > "$s/.wacli/session.db"
  echo 'ssh-ed25519 AAAAadminlogin admin-login' > "$s/.ssh/authorized_keys"
  echo deploy-key > "$s/.ssh/ocsb_vault"
  printf 'Host github-vault\n  IdentityFile %s/.ssh/ocsb_vault\n' "$O" > "$s/.ssh/config"
  echo 'github.com ssh-ed25519 AAAAhostkey' > "$s/.ssh/known_hosts"
  case "$flags" in *" symlink "*|*" symlink2 "*) rm "$s/.ssh/known_hosts"; ln -s authorized_keys "$s/.ssh/known_hosts" ;; esac
  case "$flags" in *" symlink2 "*) rm "$s/.ssh/config"; ln -s authorized_keys "$s/.ssh/config" ;; esac
  case "$flags" in *" brainlink "*) echo 'plain notes' > "$s/brain/notes"; ln -s notes "$s/brain/link" ;; esac
  case "$flags" in *" sshlink "*) rm -rf "$d/sshdir"; mv "$s/.ssh" "$d/sshdir"; ln -s "$d/sshdir" "$s/.ssh" ;; esac
  tar -C "$s" -czf "$d/filestate.tar.gz" .openclaw/.env .openclaw/gateway.systemd.env brain .wacli .ssh ops
  rm -rf "$s"
  manifest "$d" nightly
}
jget() { node -e 'const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = process.argv[2].split(".").reduce((o, k) => (o == null ? o : o[k]), c); process.stdout.write(typeof v === "string" ? v : JSON.stringify(v))' "$@"; }
mkold "$t/old"; mkold "$t/oldleft" leftover; mkold "$t/oldvault" vault; mkold "$t/oldguard" guard
mkold "$t/oldsym" symlink; mkold "$t/oldsym2" symlink2; mkold "$t/oldhp" hpfail; mkold "$t/oldscan" scanfail; mkold "$t/oldplant" plant; mkold "$t/oldbad" "home=/Users/a:b"; mkold "$t/oldskew" "home=/Users/other"
mkold "$t/oldsshl" sshlink; mkold "$t/oldblnk" brainlink
mkold "$t/oldadd" addendum; mkold "$t/oldclash" "addendum backupclash"; mkold "$t/oldskill" skillleft

fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect 0 "a nightly made by /Users/admin imports as final into another home" run_import final "$t/old"
cfg="$t/home/.openclaw/openclaw.json"
check "the import says where the archive came from" grep -qxF "import: the archive comes from /Users/admin; its paths move to $t/home" "$t/out"
check "the provider command is under the importing home" test "$(jget "$cfg" secrets.providers.op.command)" = "$t/home/.openclaw/bin/op-nosym"
check "the provider trustedDirs too" test "$(jget "$cfg" secrets.providers.op.trustedDirs)" = "[\"$t/home/.openclaw/bin\",\"/usr/bin\"]"
check "the default workspace" test "$(jget "$cfg" agents.defaults.workspace)" = "$t/home/.openclaw/workspace"
check "vera's workspace" test "$(jget "$cfg" agents.list.0.workspace)" = "$t/home/.openclaw/workspace-vera"
check "the vault path" test "$(jget "$cfg" plugins.entries.memory-wiki.config.vault)" = "$t/home/brain/vault"
check "a lookalike path is left alone" test "$(jget "$cfg" notes)" = "/Users/administrator stays"
check "the automations store's argv" grep -qF "\"$t/home/brain/harvester/harvest.mjs\"" "$t/home/.openclaw/cron/jobs.json"
check "a skill config, an ~/ops config and the harvester config" \
  bash -c 'grep -qF "\"$1/brain/queue\"" "$1/.openclaw/workspace/skills/s/config.json" && grep -qF "\"$1/backups\"" "$1/ops/bench/cfg.json" && grep -qF "\"$1/.wacli/wacli.db\"" "$1/brain/harvester/config.json"' _ "$t/home"
check "op-nosym and the ssh config, rewritten as text" \
  bash -c 'grep -qF "was $1/.openclaw/bin" "$1/.openclaw/bin/op-nosym" && grep -qF "IdentityFile $1/.ssh/ocsb_vault" "$1/.ssh/config"' _ "$t/home"
check "no live configuration names /Users/admin any more" \
  bash -c '! grep -rlE "/Users/admin([^a-z0-9]|$)" "$1/.openclaw/openclaw.json" "$1/.openclaw/cron" "$1/.openclaw/bin" "$1/.openclaw/workspace" "$1/ops" "$1/brain" "$1/.ssh"' _ "$t/home"
check "the transcript keeps its history" grep -qF '/Users/admin/brain' "$t/home/.openclaw/agents/main/sessions/t.jsonl"
check "no authorized_keys for the bot account; the deploy key, config and known_hosts are there" \
  bash -c '[ ! -e "$1/.ssh/authorized_keys" ] && [ -f "$1/.ssh/ocsb_vault" ] && [ -f "$1/.ssh/config" ] && [ -f "$1/.ssh/known_hosts" ]' _ "$t/home"
check "the rewrite is done before npm ci (and so before the token and the gateway)" ev '^npm ci .* oldhome=0 token= '
check "the token is the archive's" grep -q '^OP_SERVICE_ACCOUNT_TOKEN=old_home_value$' "$t/home/.openclaw/.env"

fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect_msg 1 "brain/prompts/p\.md: 1 reference\(s\) to /Users/admin" "free text that still names the old home fails the import, naming the file" run_import final "$t/oldleft"
check "  ... and says what to do" grep -q 'still names /Users/admin' "$t/out"
check "  ... before npm ci, the token or the gateway" bash -c '! grep -Eq "^npm |gateway install|token=set" "$1"' _ "$t/ev"

fresh; export FAKE_ARCHIVE_HOME=/Users/admin; mkdir -p "$t/home/.ssh"; echo 'ssh-ed25519 AAAAx x' > "$t/home/.ssh/authorized_keys"
expect_msg 1 "must have no SSH login" "a bot home that already accepts an SSH login is refused" run_import final "$t/old"
check "  ... before the restored state lands" test ! -e "$t/home/.openclaw"
unset FAKE_ARCHIVE_HOME

fresh
expect 0 "an archive from this same home imports as before" run_import final "$t/full"
check "  ... with no home rewrite" bash -c '! grep -Eq "^homepaths:|comes from" "$1"' _ "$t/out"
check "  ... and its authorized_keys installed" grep -q 'AAAAfixture' "$t/home/.ssh/authorized_keys"
fresh; mkdir -p "$t/home/.ssh"; echo 'ssh-ed25519 AAAAlima lima' > "$t/home/.ssh/authorized_keys"
expect 0 "the same home over the guest's own keys" run_import final "$t/full"
check "  ... keeps the guest's key and adds the archive's" bash -c 'grep -q AAAAlima "$1" && grep -q AAAAfixture "$1"' _ "$t/home/.ssh/authorized_keys"

fresh; export FAKE_RESTORE_TWICE=1
expect_msg 1 "restore layout unexpected: .*found 2" "a restore with two state dirs is refused" run_import drill "$t/full"
check "  ... before anything lands" test ! -e "$t/home/.openclaw"
unset FAKE_RESTORE_TWICE

fresh; export FAKE_UID=0
expect_msg 1 "not as root" "an import run as root is refused" run_import drill "$t/full"
check "  ... before anything is stopped or restored" bash -c '[ ! -e "$1/.openclaw" ] && ! grep -q "disable --now" "$2"' _ "$t/home" "$t/ev"
unset FAKE_UID
fresh; export FAKE_NO_MANAGER=1
expect_msg 1 "no systemd user manager" "an import without a user manager is refused" run_import drill "$t/full"
check "  ... before anything is stopped or restored" bash -c '[ ! -e "$1/.openclaw" ] && ! grep -q "disable --now" "$2"' _ "$t/home" "$t/ev"
unset FAKE_NO_MANAGER

fresh; export FAKE_TS_STATE=Running FAKE_TS_OPERATOR=
expect_msg 1 "operator must be $(id -un), not 'none'" "final with serve and no Tailscale operator refuses" run_import final "$t/tsserve"
check "  ... and touched nothing" test ! -e "$t/home/.openclaw"
fresh; export FAKE_TS_STATE=Running FAKE_TS_OPERATOR=someone-else
expect_msg 1 "not 'someone-else'" "final with serve and another account as operator refuses" run_import final "$t/tsserve"
check "  ... and touched nothing" test ! -e "$t/home/.openclaw"
unset FAKE_TS_STATE FAKE_TS_OPERATOR

fresh
expect 0 "a drill completes" run_import drill "$t/full"
check "a drill's closing hint names the rehearsal acceptance (acceptance has no drill mode)" \
  grep -qxF 'import: done (drill). Now run tests/acceptance.sh rehearsal <lan-ip>' "$t/out"
fresh
expect 0 "a final completes" run_import final "$t/full"
check "a final's closing hint names the final acceptance" grep -qxF 'import: done (final). Now run tests/acceptance.sh final <lan-ip>' "$t/out"

# ----- fix round 1 -----
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect_msg 1 "brain/vault/\.git/config: 1 reference\(s\) to /Users/admin" "the vault's git config (not walked by the scan) is scanned, and a form the rewrite leaves alone fails the import" run_import final "$t/oldvault"
check "  ... before npm ci, the token or the gateway" bash -c '! grep -Eq "^npm |gateway install|token=set" "$1"' _ "$t/ev"

fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect 0 "a cross-home import with extra .ssh files completes" run_import final "$t/oldplant"
check "only the deploy key, its public half, the config and known_hosts land (mode 600, dir 700)" \
  bash -c 'cd "$1/.ssh" && [ "$(ls -A | sort | tr "\n" " ")" = "config known_hosts ocsb_vault ocsb_vault.pub " ] && [ "$(stat -c %a . config known_hosts ocsb_vault ocsb_vault.pub 2>/dev/null || stat -f %Lp . config known_hosts ocsb_vault ocsb_vault.pub)" = "$(printf "700\n600\n600\n600\n600")" ]' _ "$t/home"
check "the private key and the other deploy key never land" bash -c '[ ! -e "$1/.ssh/id_ed25519" ] && [ ! -e "$1/.ssh/other_deploy" ]' _ "$t/home"
check "one stderr line names the skipped members, never their content" \
  bash -c 'grep -E "not restoring .ssh members" "$1" | grep -q "id_ed25519" && grep -E "not restoring .ssh members" "$1" | grep -q "other_deploy" && ! grep -Eq "^(k1|k2)$|AAAAadminlogin" "$1"' _ "$t/out"

fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect 0 "a drill of another home's archive (the rehearsal's exact mode) completes" run_import drill "$t/old"
check "  ... no WhatsApp file under HOME" no_wa_files
check "  ... cron off and nothing armed before npm ci, the old home gone" ev '^npm ci .* oldhome=0 token= cron_off=yes wa=0$'
check "  ... strip and cron-off precede the gateway install" ev '^install: wa=0 cron_off=yes$'
check "  ... no authorized_keys" test ! -e "$t/home/.ssh/authorized_keys"

fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect 0 "a cross-home import with the Tart export's macOS guard files completes" run_import final "$t/oldguard"
check "  ... they are retired, not scanned" bash -c '[ ! -e "$1/ops/listener-guard/listener-guard.mjs" ] && [ ! -e "$1/ops/listener-guard/launchd.out.log" ] && [ ! -e "$1/ops/listener-guard/launchd.err.log" ]' _ "$t/home"

fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect 0 "a cross-home import rewrites gateway.systemd.env and .env" run_import final "$t/old"
check "  ... gateway.systemd.env names the importing home" grep -qxF "PATH=$t/home/.openclaw/bin:/usr/bin" "$t/home/.openclaw/gateway.systemd.env"
check "  ... and so does .env, with the archive's token line kept" \
  bash -c 'grep -qxF "OPENCLAW_HOME_HINT=$1/.openclaw" "$1/.openclaw/.env" && grep -qxF "OP_SERVICE_ACCOUNT_TOKEN=old_home_value" "$1/.openclaw/.env"' _ "$t/home"

fresh; export FAKE_ARCHIVE_HOME=/Users/admin; export FAKE_DOCTOR_LEAK=1
expect_msg 1 "cron/leak\.json: 1 reference\(s\) to /Users/admin" "a name of the old home that doctor writes is caught by the re-scan" run_import final "$t/old"
check "  ... doctor did run first" ev 'openclaw doctor'
unset FAKE_DOCTOR_LEAK

fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect_msg 1 "home rewrite failed" "a failing home rewrite aborts the import" run_import final "$t/oldhp"
check "  ... before npm ci, the token or the gateway" bash -c '! grep -Eq "^npm |gateway install|token=set" "$1"' _ "$t/ev"
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect_msg 1 "leftover scan could not run \(exit 4" "a scan that cannot run is reported as such, not as leftovers" run_import final "$t/oldscan"
check "  ... and does not claim the config still names the old home" bash -c '! grep -q "still names" "$1"' _ "$t/out"

fresh; export FAKE_ARCHIVE_HOME=/Users/admin; mkdir -p "$t/home/.ssh"; ln -s /nonexistent-target "$t/home/.ssh/authorized_keys"
expect_msg 1 "must have no SSH login" "a dangling authorized_keys symlink counts as a login" run_import final "$t/old"
check "  ... and nothing was stopped or restored" bash -c '[ ! -e "$1/.openclaw" ] && ! grep -q "disable --now" "$2"' _ "$t/home" "$t/ev"
fresh; export FAKE_ARCHIVE_HOME=/Users/admin; mkdir -p "$t/home/.ssh"; echo k > "$t/home/.ssh/authorized_keys2"
expect_msg 1 "must have no SSH login" "authorized_keys2 counts too" run_import final "$t/old"
check "  ... and nothing was stopped or restored" bash -c '[ ! -e "$1/.openclaw" ] && ! grep -q "disable --now" "$2"' _ "$t/home" "$t/ev"
fresh; export FAKE_ARCHIVE_HOME=/Users/a:b
expect_msg 1 "not a plain absolute path" "an archive home that is not a plain path is refused" run_import final "$t/oldbad"
check "  ... before anything is stopped or restored" bash -c '[ ! -e "$1/.openclaw" ] && ! grep -q "disable --now" "$2"' _ "$t/home" "$t/ev"
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect_msg 1 "differs from the restored layout" "a listing and a restore that disagree about the home are refused" run_import final "$t/oldskew"
unset FAKE_ARCHIVE_HOME

fresh; export FAKE_RESTORE_NONE=1
expect_msg 1 "restore layout unexpected: .*found 0" "a restore with no state dir is refused" run_import drill "$t/full"
check "  ... before anything lands" test ! -e "$t/home/.openclaw"
unset FAKE_RESTORE_NONE

fresh; export FAKE_TS_STATE=Running FAKE_TS_PREFS_FAIL=1
expect_msg 1 "debug prefs' failed" "final with serve and a failing 'tailscale debug prefs' says so" run_import final "$t/tsserve"
check "  ... and touched nothing" test ! -e "$t/home/.openclaw"
unset FAKE_TS_STATE FAKE_TS_PREFS_FAIL

# ----- fix round 2 -----
# Since round 4 the archive's symlink under .ssh is refused at validation, before anything is stopped (fixture (b)).
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect_msg 1 "symlink at or under \.ssh.*: \.ssh/known_hosts$" "a symlinked .ssh/known_hosts in the archive is refused, naming only the member" run_import final "$t/oldsym"
check "  ... and no authorized_keys exists afterwards, nor the link" bash -c '[ ! -e "$1/.ssh/authorized_keys" ] && [ ! -L "$1/.ssh/known_hosts" ] && [ ! -e "$1/.ssh/known_hosts" ]' _ "$t/home"
check "  ... before anything is stopped or restored" bash -c '[ ! -e "$1/.openclaw" ] && ! grep -Eq "disable --now|backup restore" "$2"' _ "$t/home" "$t/ev"

fresh; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_TAR_FAIL=1
expect 2 "a failing file-state extraction aborts the import (tar's own status under set -e)" run_import final "$t/old"
check "  ... and leaves no member list behind" bash -c '[ -z "$(find "$1" -maxdepth 1 -name ".import-members.*")" ]' _ "$t/home"
unset FAKE_TAR_FAIL FAKE_ARCHIVE_HOME

fresh; export FAKE_TS_STATE=Running FAKE_TS_PREFS_BAD=1
expect_msg 1 "cannot read OperatorUser" "final with serve and prefs that are not JSON says so" run_import final "$t/tsserve"
check "  ... and touched nothing" test ! -e "$t/home/.openclaw"
unset FAKE_TS_STATE FAKE_TS_PREFS_BAD

# The archive can no longer deliver these links (round 4 refuses them at validation), so the shim leaves them behind
# after the extraction, as a tar writing through a link would.
fresh; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_TAR_PLANT=links
expect_msg 1 "removed \.ssh entries.*config known_hosts" "two symlinked allowed names are both removed before the import dies" run_import final "$t/old"
check "  ... neither is left in .ssh, and no authorized_keys exists" bash -c '[ ! -e "$1/.ssh/config" ] && [ ! -L "$1/.ssh/config" ] && [ ! -L "$1/.ssh/known_hosts" ] && [ ! -e "$1/.ssh/authorized_keys" ]' _ "$t/home"
check "  ... the .ssh modes were applied before the die" bash -c '[ "$(stat -c %a "$1/.ssh/ocsb_vault" 2>/dev/null || stat -f %Lp "$1/.ssh/ocsb_vault")" = 600 ]' _ "$t/home"

fresh; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_TAR_PLANT="ak x"
expect_msg 1 "removed \.ssh entries.*id_x" "an extra .ssh entry left behind by tar is removed and the import dies" run_import final "$t/old"
check "  ... the extra entry and the login key are both gone" bash -c '[ ! -e "$1/.ssh/id_x" ] && [ ! -e "$1/.ssh/authorized_keys" ]' _ "$t/home"
check "  ... before npm ci, the token or the gateway" bash -c '! grep -Eq "^npm |gateway install|token=set" "$1"' _ "$t/ev"
fresh; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_TAR_PLANT="ak"
expect_msg 1 "must have no SSH login" "a login key left behind by tar fails the import" run_import final "$t/old"
check "  ... and is removed" test ! -e "$t/home/.ssh/authorized_keys"
fresh; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_TAR_PLANT="x"
expect_msg 1 "removed \.ssh entries.*id_x" "an unexpected .ssh entry alone fails the import" run_import final "$t/old"
check "  ... and is removed" test ! -e "$t/home/.ssh/id_x"
unset FAKE_TAR_PLANT FAKE_ARCHIVE_HOME

# ----- fix round 4 -----
# A symlink at or under .ssh in another home's file state is refused at validation, before anything is stopped, naming
# the members only; a symlink elsewhere, and a same-home import, are not affected.
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect_msg 1 "symlink at or under \.ssh.*: \.ssh$" "an archive whose .ssh is itself a symlink is refused, naming only the member" run_import final "$t/oldsshl"
check "  ... before any disable --now, and no .openclaw restored" \
  bash -c '[ ! -e "$1/.openclaw" ] && [ ! -e "$1/.ssh" ] && [ ! -L "$1/.ssh" ] && ! grep -Eq "disable --now|backup restore" "$2"' _ "$t/home" "$t/ev"
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect_msg 1 "symlink at or under \.ssh.*: (\.ssh/config \.ssh/known_hosts|\.ssh/known_hosts \.ssh/config)$" "every symlinked .ssh member is named" run_import final "$t/oldsym2"
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect 0 "an ordinary symlink elsewhere in another home's archive (brain/link -> notes) is accepted" run_import final "$t/oldblnk"
check "  ... and lands as that symlink" bash -c '[ -L "$1/brain/link" ] && [ "$(readlink "$1/brain/link")" = notes ]' _ "$t/home"
fresh; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_TAR_VEXTRA=1
expect_msg 1 "listings of filestate\.tar\.gz differ" "plain and verbose listings that do not pair line by line are refused" run_import final "$t/old"
check "  ... before any disable --now" bash -c '! grep -q "disable --now" "$1"' _ "$t/ev"
unset FAKE_TAR_VEXTRA FAKE_ARCHIVE_HOME
# A backup listing that shows no home (fbl, made like the full fixture and archived as ./ names): on the same home its
# .ssh symlink is not affected; from another home the import is known to be cross-home only after the restore, and is
# refused there, before the state lands.
rm -rf "$t/fbl"; mkdir -p "$t/fbl/s"; cp "$t/full/openclaw-backup.tar.gz" "$t/fbl/"
tar -C "$t/fbl/s" -xzf "$t/full/filestate.tar.gz"; ln -s authorized_keys "$t/fbl/s/.ssh/known_hosts"
tar -C "$t/fbl/s" -czf "$t/fbl/filestate.tar.gz" .; rm -rf "$t/fbl/s"; manifest "$t/fbl" final
fresh
expect 0 "a same-home archive with a symlink under .ssh is not affected" run_import final "$t/fbl"
check "  ... and the link lands" test -L "$t/home/.ssh/known_hosts"
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect_msg 1 "symlink at or under \.ssh.*: \./\.ssh/known_hosts$" "with no home in the listing, a cross-home archive's .ssh symlink is refused after the restore (./ names normalised)" run_import final "$t/fbl"
check "  ... before the restored state lands" test ! -e "$t/home/.openclaw"
unset FAKE_ARCHIVE_HOME

# After the extraction .ssh must be a real directory before anything removes, merges or chmods in it: the link goes,
# the import dies, and the link's target is left exactly as it was.
mktarget() { rm -rf "$t/home.target"; mkdir -p "$t/home.target"; echo t1 > "$t/home.target/id_other"; echo t2 > "$t/home.target/config"; chmod 644 "$t/home.target/id_other" "$t/home.target/config"; chmod 755 "$t/home.target"; }
target_same() ( cd "$t/home.target" && [ "$(find . -mindepth 1 | sort | tr '\n' ' ')" = "./config ./id_other " ] && [ "$(cat id_other)" = t1 ] && [ "$(cat config)" = t2 ] \
  && [ "$(stat -c %a . config id_other 2>/dev/null || stat -f %Lp . config id_other)" = "$(printf '755\n644\n644')" ] )
fresh; mktarget; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_TAR_PLANT=sshlink
expect_msg 1 "\.ssh in the archive is not a directory \(removed\)" "a .ssh that is a symlink after the extraction stops the import before anything acts on it" run_import final "$t/old"
check "  ... the link is gone" bash -c '[ ! -L "$1/.ssh" ] && [ ! -e "$1/.ssh" ]' _ "$t/home"
check "  ... its target's contents and mode are unchanged" target_same
check "  ... before npm ci, the token or the gateway" bash -c '! grep -Eq "^npm |gateway install|token=set" "$1"' _ "$t/ev"
fresh; mktarget; mkdir -p "$t/home/.ssh"; echo 'ssh-ed25519 AAAAlima lima' > "$t/home/.ssh/authorized_keys"; export FAKE_TAR_PLANT=sshlink
expect_msg 1 "\.ssh in the archive is not a directory \(removed\)" "on a same-home import too, before the key merge and the chmod" run_import final "$t/full"
check "  ... its target's contents and mode are unchanged (same home)" target_same
unset FAKE_TAR_PLANT

# An authorized_keys that is a directory is removed too, and the import dies with its own message.
fresh; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_TAR_PLANT=akdir
expect_msg 1 "must have no SSH login" "an authorized_keys directory left behind by tar is removed and refused" run_import final "$t/old"
check "  ... and is gone" bash -c '[ ! -e "$1/.ssh/authorized_keys" ] && [ ! -L "$1/.ssh/authorized_keys" ]' _ "$t/home"
unset FAKE_TAR_PLANT FAKE_ARCHIVE_HOME

# ----- fix round 5 -----
# A ~/.ssh that is already a symlink before the import is refused at validation, on either kind of import, and never
# removed or written through: the link stays, its target is unchanged, nothing is stopped or restored.
for kind in same cross; do
  fresh; mktarget; ln -s "$t/home.target" "$t/home/.ssh"
  if [ "$kind" = same ]; then fx="$t/full"; else fx="$t/old"; export FAKE_ARCHIVE_HOME=/Users/admin; fi
  expect_msg 1 "\.ssh is a symlink or not a directory; the import never writes, merges or chmods through it.*\(nothing was changed\)" \
    "a $kind-home import over a ~/.ssh that is already a symlink is refused" run_import final "$fx"
  check "  ... the link is still there ($kind home)" test -L "$t/home/.ssh"
  check "  ... its target's names, contents and modes are unchanged ($kind home)" target_same
  check "  ... nothing was stopped and no .openclaw restored ($kind home)" bash -c '[ ! -e "$1/.openclaw" ] && ! grep -q "disable --now" "$2"' _ "$t/home" "$t/ev"
done
unset FAKE_ARCHIVE_HOME

# The allowed-name type check's other branch: an allowed name that extraction left as a directory.
fresh; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_TAR_PLANT=khdir
expect_msg 1 "removed \.ssh entries.*known_hosts" "an allowed .ssh name left as a directory is removed and the import dies" run_import final "$t/old"
check "  ... and it is gone" bash -c '[ ! -e "$1/.ssh/known_hosts" ] && [ ! -L "$1/.ssh/known_hosts" ]' _ "$t/home"
unset FAKE_TAR_PLANT FAKE_ARCHIVE_HOME

# GNU tar credits every member under a listed directory entry to that one entry unless the list is --no-recursion:
# the cross-home extraction must be run with it. The suite normally runs under bsdtar, so this needs a GNU tar.
gnutar=""
if command -v gtar >/dev/null 2>&1; then gnutar=$(command -v gtar)
elif tar --version 2>&1 | grep -q 'GNU tar'; then gnutar=$(command -v tar); fi
if [ -n "$gnutar" ]; then
  fresh; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_REAL_TAR="$gnutar"
  expect 0 "cross-home extraction under GNU tar (directory entries in the member list)" run_import final "$t/oldplant"
  check "  ... the state landed and exactly the four allowed .ssh files with it" \
    bash -c 'cd "$1" && [ -f brain/harvester/package-lock.json ] && [ -f ops/bench/cfg.json ] && [ -f .wacli/session.db ] && [ "$(ls -A .ssh | sort | tr "\n" " ")" = "config known_hosts ocsb_vault ocsb_vault.pub " ]' _ "$t/home"
  # An archive that makes `lnk -> .ssh` and then lists lnk/authorized_keys: GNU tar writes through its own symlink.
  rm -rf "$t/oldlnk"; cp -R "$t/old" "$t/oldlnk"
  mkdir -p "$t/lnk1" "$t/lnk2/lnk"; ln -s .ssh "$t/lnk1/lnk"; echo planted > "$t/lnk2/lnk/authorized_keys"
  gzip -dc "$t/oldlnk/filestate.tar.gz" > "$t/oldlnk/f.tar"
  "$gnutar" -rf "$t/oldlnk/f.tar" -C "$t/lnk1" lnk && "$gnutar" -rf "$t/oldlnk/f.tar" -C "$t/lnk2" lnk/authorized_keys
  gzip -c "$t/oldlnk/f.tar" > "$t/oldlnk/filestate.tar.gz"; rm -f "$t/oldlnk/f.tar"
  manifest "$t/oldlnk" nightly
  fresh; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_REAL_TAR="$gnutar"
  expect_msg 1 "must have no SSH login" "an archive that writes authorized_keys through its own symlink fails the import (GNU tar)" run_import final "$t/oldlnk"
  check "  ... and no .ssh/authorized_keys remains" test ! -e "$t/home/.ssh/authorized_keys"
  unset FAKE_ARCHIVE_HOME FAKE_REAL_TAR
else
  echo "SKIP: GNU tar not found (cross-home extraction)"
fi

# ----- the OpenClaw state-path migration (spec 2026-10-02, addendum 2026-10-05) -----
# A cross-home import runs migrate/state-paths.py once the restored state has landed and before any openclaw command but
# the restore itself (a config write records the new home; doctor --fix stales the Workshop proposals).
sp_line() { grep -n '^python3 ' "$t/ev" | head -1 | cut -d: -f1; }
only_restore_before_state_paths() { # every openclaw event before the migration is the restore
  local n; n=$(sp_line); [ -n "$n" ] || return 1
  [ "$(head -n "$((n - 1))" "$t/ev" | grep '^openclaw ' | grep -vc '^openclaw backup restore ')" -eq 0 ]
}
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect 0 "a cross-home final import completes with the state-path migration" run_import final "$t/old"
check "the migration runs once, with the archive's home, this home and its state dir, once the state has landed" \
  bash -c '[ "$(grep -c "^python3 " "$1")" -eq 1 ] && grep -qxF "python3 $2/state-paths.py migrate --old /Users/admin --new $3 --state $3/.openclaw | landed=yes" "$1"' _ "$t/ev" "$here" "$t/home"
check "  ... after the move into place" in_order '^mv-into-place ' '^python3 '
check "  ... and no openclaw command but the restore comes before it" only_restore_before_state_paths
check "  ... nor doctor or the gateway install" in_order '^python3 ' 'openclaw gateway install' 'openclaw doctor '
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect 0 "a cross-home drill completes with the state-path migration" run_import drill "$t/old"
check "  ... which precedes the drill's first config write (cron off)" in_order '^python3 .*/state-paths\.py migrate ' 'openclaw config set cron\.enabled false'
check "  ... and every other openclaw command but the restore" only_restore_before_state_paths
unset FAKE_ARCHIVE_HOME
fresh
expect 0 "a same-home import completes" run_import final "$t/full"
check "  ... and never runs the state-path migration" bash -c '! grep -q "^python3 " "$1"' _ "$t/ev"

fresh; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_PY_RC=1
expect_msg 1 "import: the OpenClaw state-path migration failed closed" "a migration that refuses fails the import" run_import final "$t/old"
check "  ... with its own reason shown" grep -q 'state-paths: refused: simulated' "$t/out"
check "  ... and no openclaw command after the restore, no npm ci, no file rewrite" \
  bash -c '[ "$(grep "^openclaw " "$1" | grep -vc "^openclaw backup restore ")" -eq 0 ] && ! grep -q "^npm " "$1" && ! grep -q "^homepaths:" "$2"' _ "$t/ev" "$t/out"
check "  ... and it does not speak of a partial commit" bash -c '! grep -q "committed part of its work" "$1"' _ "$t/out"
# Exit 3: a COMMIT failed after an earlier database committed (fix round 1, minor 3).
fresh; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_PY_RC=3
expect_msg 1 "import: the OpenClaw state-path migration committed part of its work and then failed \\(see above\\): this state is inconsistent; nothing after the migration ran on it: rehome\\.sh rollback, then switch again" \
  "a migration that commits only part of its work fails the import, says so and points at rollback" run_import final "$t/old"
check "  ... not as a closed failure" bash -c '! grep -q "failed closed" "$1"' _ "$t/out"
check "  ... and nothing runs after it" \
  bash -c '[ "$(grep "^openclaw " "$1" | grep -vc "^openclaw backup restore ")" -eq 0 ] && ! grep -q "^npm " "$1" && ! grep -q "^homepaths:" "$2"' _ "$t/ev" "$t/out"
unset FAKE_ARCHIVE_HOME FAKE_PY_RC

# python3 is checked before anything is stopped. A PATH with every command of this one but python.
mkdir -p "$t/nopy"
printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
  if [ -d "$d" ]; then ln -s "$d"/* "$t/nopy/" 2>/dev/null || true; fi
done
rm -f "$t/nopy"/python*
cp -R "$t/bin" "$t/nopybin"; rm -f "$t/nopybin/python3"
run_import_nopy() { env IMPORT_DRY=0 FAKE_LOG="$t/ev" PATH="$t/nopybin:$t/nopy" bash "$here/import.sh" "$@"; }
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect_msg 1 "python3 not found on PATH: a cross-home import needs it" "a cross-home import without python3 is refused" run_import_nopy final "$t/old"
check "  ... saying what this import did, not that nothing was stopped (in a rehome switch admin's units already are)" \
  bash -c 'grep -q "this import has stopped and changed nothing" "$1" && ! grep -q "nothing was stopped" "$1"' _ "$t/out"
check "  ... before anything is stopped or restored" bash -c '[ ! -e "$1/.openclaw" ] && ! grep -Eq "disable --now|backup restore" "$2"' _ "$t/home" "$t/ev"
unset FAKE_ARCHIVE_HOME
fresh
expect_msg 1 "python3 not found on PATH" "an archive whose listing shows no home may be cross-home: it needs python3 too" run_import_nopy final "$t/full"
mkold "$t/oldsame" "home=$t/home"
fresh
expect 0 "a same-home import (its listing shows this home) needs no python3" run_import_nopy final "$t/oldsame"
check "  ... and runs no migration" bash -c '! grep -q "^python3 " "$1" && ! grep -q "comes from" "$2"' _ "$t/ev" "$t/out"
mkdir -p "$t/nosp/migrate" "$t/nosp/ops/listener-guard" "$t/nosp/ops/lib"
cp "$here/import.sh" "$here/homepaths.mjs" "$here/scan-refs.mjs" "$t/nosp/migrate/"; cp -R "$here/lib" "$t/nosp/migrate/"
: > "$t/nosp/ops/listener-guard/guard.mjs"; cp "$here/../ops/lib/dotenv-token.sh" "$t/nosp/ops/lib/"
fresh
expect_msg 1 "migrate/state-paths\.py missing from the repo checkout" "a repo checkout without state-paths.py is refused" env IMPORT_DRY=0 FAKE_LOG="$t/ev" PATH="$t/bin:$PATH" bash "$t/nosp/migrate/import.sh" drill "$t/full"
check "  ... before anything is stopped" bash -c '! grep -q "disable --now" "$1"' _ "$t/ev"

# The files the addendum moves (Codex trust, a Workshop skill, the workspace scripts, the memory project annotations),
# and admin's openclaw.json backups moved aside, never deleted (the aside dir is no scan root: they name the old home).
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect 0 "a cross-home import of state with the addendum's files completes" run_import final "$t/oldadd"
oc="$t/home/.openclaw"
check "Codex's project trust names this home" grep -qxF "[projects.\"$oc/workspace\"]" "$oc/agents/main/agent/codex-home/config.toml"
check "the Workshop skill too" grep -qxF "Run python3 $oc/workspace/gen_chart.py first." "$oc/agents/main/agent/workshop-skills/charts/SKILL.md"
check "the workspace scripts too" \
  bash -c 'grep -qxF "OUT = \"$1/workspace/charts\"" "$1/workspace/gen_chart.py" && grep -qxF "cd $2/brain && ./go" "$1/workspace/scripts/fetch.sh"' _ "$oc" "$t/home"
check "a memory note's project annotation names this home, and its text keeps its history" \
  bash -c '[ "$(cat "$1/workspace/memory/2026-09-01.md")" = "$(printf "<!-- project: path:%s/workspace -->\nNotes on /Users/admin/brain." "$1")" ]' _ "$oc"
check "the ~ form in DREAMS.md too" grep -qxF "<!-- project: path:$oc/workspace -->" "$oc/workspace/DREAMS.md"
check "admin's config backups are aside, unchanged, and none is left where OpenClaw looks" \
  bash -c 'cd "$1" && for b in last-good bak bak.1 pre-update clobbered.20260901T000000Z; do [ ! -e "openclaw.json.$b" ] && grep -qF "\"was\":\"$b\"" "pre-rehome-config-backups/openclaw.json.$b" && grep -qF /Users/admin/.openclaw "pre-rehome-config-backups/openclaw.json.$b" || exit 1; done' _ "$oc"
check "  ... in a 700 dir, and the import says so" \
  bash -c '[ "$(ls -ld "$1" | cut -c1-10)" = drwx------ ] && grep -q "moved 5 openclaw.json backup(s) of /Users/admin aside" "$2"' _ "$oc/pre-rehome-config-backups" "$t/out"
check "  ... before the home rewrite" bash -c '[ "$(grep -n "moved 5 openclaw.json" "$1" | cut -d: -f1)" -lt "$(grep -n "^homepaths: " "$1" | head -1 | cut -d: -f1)" ]' _ "$t/out"
check "  ... and before any config write" bash -c 'grep -q "^config-write " "$1" && ! grep -q "^config-write backups=[1-9]" "$1"' _ "$t/ev"
# A drill writes config right after the state lands (cron off): OpenClaw's own .bak rotation must not run on admin's
# backups first (fix round 1, minor 1).
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect 0 "a cross-home drill of state with config backups completes" run_import drill "$t/oldadd"
check "admin's config backups are aside before the drill's first config write (cron off)" \
  bash -c 'grep -q "^config-write " "$1" && ! grep -q "^config-write backups=[1-9]" "$1"' _ "$t/ev"
check "  ... and after the state-path migration" in_order '^python3 .*/state-paths\.py migrate ' '^openclaw config set cron\.enabled false '
check "  ... all five of them" bash -c 'cd "$1" && [ "$(ls pre-rehome-config-backups | grep -c "^openclaw")" -eq 5 ]' _ "$t/home/.openclaw"
# The drill's own config writes rotate .bak* of the landed, not yet rewritten config (it names the old home): none may
# stay where OpenClaw looks (fix round 2, item 1).
fresh; export FAKE_ARCHIVE_HOME=/Users/admin FAKE_ROTATE=1
expect 0 "a cross-home drill whose config writes rotate .bak completes" run_import drill "$t/oldadd"
unset FAKE_ROTATE
oc="$t/home/.openclaw"
check "no openclaw.json.bak* naming the old home is left in the live dir" \
  bash -c 'cd "$1" && ls openclaw.json.bak* >/dev/null 2>&1 && ! grep -lE "/Users/admin([^a-z0-9]|$)" openclaw.json.bak* | grep -q .' _ "$oc"
check "  ... the rotated ones were moved aside into drill-writes (700), and the first pass's are untouched" \
  bash -c 'cd "$1/pre-rehome-config-backups" && ls drill-writes/openclaw.json.bak* >/dev/null 2>&1 && [ "$(ls -ld drill-writes | cut -c1-10)" = drwx------ ] && [ "$(ls | grep -c "^openclaw")" -eq 5 ]' _ "$oc"
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect_msg 1 "pre-rehome-config-backups/openclaw\.json\.bak exists already; refusing to overwrite" "a backup already in the aside dir stops the import" run_import final "$t/oldclash"
check "  ... deleting nothing: both copies are still there" \
  bash -c '[ "$(cat "$1/pre-rehome-config-backups/openclaw.json.bak")" = earlier ] && grep -q "\"was\":\"bak\"" "$1/openclaw.json.bak"' _ "$oc"
check "  ... before npm ci, the token or the gateway" bash -c '! grep -Eq "^npm |gateway install|token=set" "$1"' _ "$t/ev"
fresh; export FAKE_ARCHIVE_HOME=/Users/admin
expect_msg 1 "workshop-skills/charts/notes\.txt: 1 reference\(s\) to /Users/admin" "a Workshop skill's other file that names the old home fails the import's scan" run_import final "$t/oldskill"
unset FAKE_ARCHIVE_HOME

# ===== Part 3: export.sh against a fake home ======================================================
if command -v shasum >/dev/null 2>&1; then
  xhome="$t/xhome"; mkdir -p "$t/xbin"
  cat > "$t/xbin/openclaw" <<'EOF'
#!/bin/bash
# fake: `openclaw backup create --dry-run --json` (the plan) and `... --output DIR --verify` (the archive)
if [ "$3" = --dry-run ]; then
  [ -z "${FAKE_DRYRUN_FAIL:-}" ] || exit 1
  cat <<JSON
{"assets":[{"kind":"state","sourcePath":"$HOME/.openclaw"}],
 "skipped":[{"kind":"workspace","sourcePath":"$HOME/.openclaw/workspace","reason":"covered","coveredBy":"$HOME/.openclaw"},
            {"kind":"managed state","sourcePath":"$HOME/.openclaw/npm","reason":"regenerable"},
            {"kind":"plugin dependencies","sourcePath":"$HOME/.openclaw/npm/projects/p/node_modules","reason":"regenerable"}]}
JSON
  exit 0
fi
tar -czf "$4/2026-01-01T00-00-00.000+00-00-openclaw-backup.tar.gz" -C "$HOME" .openclaw
EOF
  cat > "$t/xbin/launchctl" <<'EOF'
#!/bin/bash
echo "launchctl $*" >> "$FAKE_LOG"
if [ "$1" = print ]; then [ "${FAKE_GUARD_LOADED:-0}" = 1 ]; exit $?; fi
exit 0
EOF
  cat > "$t/xbin/df" <<'EOF'
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/fake 1000000000 1 ${FAKE_DF_AVAIL_KB:-1000000000} 1% /"
EOF
  chmod +x "$t/xbin/"*
  mkxhome() {
    rm -rf "$xhome" "$t/xev"; : > "$t/xev"
    mkdir -p "$xhome/.openclaw/service-env" "$xhome/brain/app/node_modules/pkg" "$xhome/.wacli" "$xhome/.ssh" "$xhome/ops"
    echo 'export X=1' > "$xhome/.openclaw/service-env/ai.openclaw.gateway.env"
    echo '{}' > "$xhome/.openclaw/openclaw.json"
    echo a > "$xhome/brain/app/a.txt"; echo b > "$xhome/brain/app/node_modules/pkg/b.js"
    echo s > "$xhome/.wacli/session.db"; echo m > "$xhome/.wacli/messages.db"
    for f in ocsb_vault ocsb_vault.pub config authorized_keys known_hosts; do echo k > "$xhome/.ssh/$f"; done
    echo o > "$xhome/ops/x.sh"
  }
  mib3() { head -c 3145728 /dev/zero > "$1"; }
  mkxhome_big() { # files the export does not archive (3 MiB each); with "keep": 2 MiB that it does
    mkxhome
    mkdir -p "$xhome/.openclaw/npm/projects/p/node_modules/q"
    mib3 "$xhome/.openclaw/npm/projects/p/node_modules/q/dep.bin"
    mib3 "$xhome/brain/app/node_modules/pkg/big.bin"
    mib3 "$xhome/.wacli/session.db"
    if [ "${1:-}" = keep ]; then head -c 2097152 /dev/zero > "$xhome/.openclaw/keep.bin"; fi
  }
  room_kb() { echo $((1048576 + $1)); }   # the 1 GiB margin plus this many kB
  run_export() { env HOME="$xhome" FAKE_LOG="$t/xev" PATH="$t/xbin:$PATH" bash "$here/export.sh" "$@"; }
  xdir() { find "$xhome" -maxdepth 1 -type d -name "claw-export-$1-*" | head -1; }
  unset FAKE_DF_AVAIL_KB FAKE_GUARD_LOADED || true

  mkxhome; export FAKE_DF_AVAIL_KB=100
  expect_msg 1 "not enough free space.*estimated export size [0-9]+ MiB \+ 1024 MiB margin = [0-9]+ MiB needed, 0 MiB free" \
    "export refuses to start when the disk cannot hold it, and says what it estimated" run_export rehearsal
  check "a refused export wrote nothing" test -z "$(xdir rehearsal)"
  # The owner can skip the check knowingly; it says so.
  export CLAW_EXPORT_SKIP_SPACE_CHECK=1
  expect_msg 0 "WARNING: free-space check skipped" "CLAW_EXPORT_SKIP_SPACE_CHECK=1 lets a tight export run, with a warning" run_export rehearsal
  check "the export ran under the override" test -n "$(xdir rehearsal)"
  unset CLAW_EXPORT_SKIP_SPACE_CHECK FAKE_DF_AVAIL_KB

  # The estimate counts what is archived, not the raw size of the parents: 9 MiB of plugin dependencies, brain
  # node_modules and (in rehearsal) the wacli session are never exported, so 2 MiB over the margin is enough.
  mkxhome_big; export FAKE_DF_AVAIL_KB; FAKE_DF_AVAIL_KB=$(room_kb 2048)
  expect 0 "a rehearsal export fits when only unexported bulk would overflow the disk" run_export rehearsal
  mkxhome_big
  expect_msg 1 "not enough free space" "a final export counts the wacli session it archives" run_export final
  # A skipped path nested inside another skipped path must not be subtracted twice: here 2 MiB really is
  # archived and only 1 MiB of room is left over the margin.
  mkxhome_big keep; FAKE_DF_AVAIL_KB=$(room_kb 1024)
  expect_msg 1 "not enough free space" "nested skipped paths are subtracted once" run_export rehearsal
  mkxhome_big; export FAKE_DRYRUN_FAIL=1
  expect_msg 1 "cannot plan the backup" "an estimate that cannot be made refuses instead of guessing" run_export rehearsal
  unset FAKE_DRYRUN_FAIL FAKE_DF_AVAIL_KB

  mkxhome
  expect 0 "a rehearsal export completes" run_export rehearsal
  d=$(xdir rehearsal)
  check "rehearsal export has exactly the three files, mode line first" \
    bash -c 'cd "$1" && [ "$(ls | LC_ALL=C sort | tr "\n" " ")" = "MANIFEST filestate.tar.gz openclaw-backup.tar.gz " ] && [ "$(head -1 MANIFEST)" = mode=rehearsal ]' _ "$d"
  check "rehearsal export checksums verify" bash -c 'cd "$1" && grep -v "^mode=" MANIFEST | shasum -a 256 -c -' _ "$d"
  check "rehearsal filestate carries no wacli session but the rest of the store" \
    bash -c '! tar -tzf "$1/filestate.tar.gz" | grep -q session.db && tar -tzf "$1/filestate.tar.gz" | grep -q "^.wacli/messages.db$"' _ "$d"
  check "filestate leaves out brain node_modules" bash -c '! tar -tzf "$1/filestate.tar.gz" | grep -q node_modules && tar -tzf "$1/filestate.tar.gz" | grep -q "^brain/app/a.txt$"' _ "$d"
  check "rehearsal never touches launchd" bash -c '! grep -q bootout "$1"' _ "$t/xev"

  mkxhome; export FAKE_GUARD_LOADED=1
  expect_msg 1 "still loaded after bootout" "final export refuses when the guard bootout did not take" run_export final
  check "the gateway was not booted out under a live guard" bash -c '! grep -q "bootout .*ai.openclaw.gateway" "$1"' _ "$t/xev"
  check "the refused final export left no directory" test -z "$(xdir final)"
  unset FAKE_GUARD_LOADED

  mkxhome
  expect 0 "a final export completes once the guard is gone" run_export final
  d=$(xdir final)
  check "final export booted out guard then gateway, and keeps the wacli session" \
    bash -c 'grep bootout "$2" | head -2 | tr "\n" " " | grep -q "local.openclaw-listener-guard.*ai.openclaw.gateway" && [ "$(head -1 "$1/MANIFEST")" = mode=final ] && tar -tzf "$1/filestate.tar.gz" | grep -q "^.wacli/session.db$"' _ "$d" "$t/xev"
fi

echo "import guard rails: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
