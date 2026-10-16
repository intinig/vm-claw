#!/bin/bash
# Tests for host/claw.sh, and for the instance default of tests/isolation-check.sh, against a fake limactl and git
# first on PATH. The fake limactl logs each call as `limactl [arg] [arg] ... stdin=<bytes>`, one bracket per
# argument, so word boundaries and quoting are visible. With FAKE_EXEC=1 it runs a `shell` command here instead
# (the deploy script, with /opt/vm-claw mapped onto $FAKE_OPT). Nothing reaches a real VM. Runs under /bin/bash 3.2.
# shellcheck disable=SC2016  # bash -c snippets are single-quoted on purpose
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
pass=0; fail=0
check() { # check <description> <cmd...>: the command must succeed
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL: $desc"
    { sed 's/^/    log: /' "$t/log" 2>/dev/null | tail -6; } || true
    { sed 's/^/    err: /' "$t/err" 2>/dev/null | tail -4; } || true
  fi
}
mkdir -p "$t/bin" "$t/opt"
cat > "$t/bin/limactl" <<'EOF'
#!/bin/bash
if [ -n "${FAKE_EXEC:-}" ] && [ "$1" = shell ]; then
  { printf 'limactl'; printf ' [%s]' "$@"; printf ' stdin=exec\n'; } >> "$FAKE_LOG"
  shift; if [ "$1" = --workdir ]; then shift 2; fi; shift      # --workdir /, then the instance
  if [ "$1" = -- ]; then shift; fi
  if [ "$1" = sudo ]; then shift; fi
  if [ "$1" = -n ]; then shift; fi
  args=(); for a in "$@"; do if [ "$a" = /opt/vm-claw ]; then args+=("$FAKE_OPT/vm-claw"); else args+=("$a"); fi; done
  exec "${args[@]}"
fi
{ printf 'limactl'; printf ' [%s]' "$@"; printf ' stdin=%s\n' "$(wc -c | tr -d ' ')"; } >> "$FAKE_LOG"
exit "${FAKE_LIMA_RC:-0}"
EOF
cat > "$t/bin/git" <<'EOF'
#!/bin/bash
echo "git $*" >> "$FAKE_LOG"
case "$*" in
  *" rev-parse HEAD") echo 0123456789abcdef0123456789abcdef01234567 ;;
  *" status --porcelain") printf '%s' "${FAKE_DIRTY:-}" ;;
  *" archive --format=tar HEAD")
    if [ -n "${FAKE_TREE:-}" ]; then tar -cf - -C "$FAKE_TREE" .; else printf 'fake-tar-bytes'; fi ;;
esac
EOF
printf '#!/bin/bash\necho "chown $*" >> "$FAKE_LOG"\n' > "$t/bin/chown"
chmod +x "$t/bin/"*

rc=0
cw() { # cw [NAME=value ...] -- <claw.sh args...>: run host/claw.sh against the fakes; log in $t/log, status in $rc
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "$t/log"
  set +e
  env -u CLAW_INSTANCE ${envs[@]+"${envs[@]}"} FAKE_LOG="$t/log" PATH="$t/bin:$PATH" bash "$repo/host/claw.sh" "$@" </dev/null >"$t/out" 2>"$t/err"
  rc=$?
  set -e
}
logged() { grep -qxF -- "$1" "$t/log"; }                       # a whole log line, literally
log_has() { grep -qF -- "$1" "$t/log"; }                       # a fragment, literally
line_of() { grep -nF -- "$1" "$t/log" | head -1 | cut -d: -f1; }
SESSION='[sudo] [-n] [-u] [sebastian] [--] [env] [-C] [/home/sebastian] [HOME=/home/sebastian] [USER=sebastian] [LOGNAME=sebastian] [XDG_RUNTIME_DIR=/run/user/2000] [DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/2000/bus]'
REV=0123456789abcdef0123456789abcdef01234567

# --- the instance ---
cw -- start
check "no CLAW_INSTANCE: the instance is claw" logged 'limactl [start] [claw] stdin=0'
cw CLAW_INSTANCE=claw-drill -- start
check "CLAW_INSTANCE picks the instance" logged 'limactl [start] [claw-drill] stdin=0'
cw CLAW_INSTANCE=claw-drill -- create --memory 4
check "create names the instance and passes the memory" logged "limactl [create] [--name=claw-drill] [--memory=4] [--tty=false] [$repo/lima/claw.yaml] stdin=0"
cw -- create
check "create defaults to 8 GiB" logged "limactl [create] [--name=claw] [--memory=8] [--tty=false] [$repo/lima/claw.yaml] stdin=0"
cw -- create --memory
check "create --memory without a size: usage, nothing run" bash -c '[ "$1" -eq 2 ] && [ ! -s "$2" ]' _ "$rc" "$t/log"
for bad in 'bad name' 'x;y' '-x' 'Claw' '../claw' 'claw:x'; do
  cw "CLAW_INSTANCE=$bad" -- start
  check "CLAW_INSTANCE '$bad' is refused before any limactl call" \
    bash -c '[ "$1" -eq 2 ] && [ ! -s "$2" ] && grep -q "is not an instance name" "$3"' _ "$rc" "$t/log" "$t/err"
done

# --- admin's shell, unchanged ---
cw -- shell -- id -un
check "shell -- cmd runs as admin, as before" logged 'limactl [shell] [claw] [--] [id] [-un] stdin=0'
cw -- shell
check "shell alone opens admin's shell" logged 'limactl [shell] [claw] [--] stdin=0'

# --- the bot ---
cw -- sebastian -- systemctl --user status openclaw-gateway.service
check "sebastian -- cmd: as the bot through sudo, with a user-session environment, from /" \
  logged "limactl [shell] [--workdir] [/] [claw] [--] $SESSION [systemctl] [--user] [status] [openclaw-gateway.service] stdin=0"
cw CLAW_INSTANCE=claw-drill -- sebastian -- id
check "sebastian honours CLAW_INSTANCE" logged "limactl [shell] [--workdir] [/] [claw-drill] [--] $SESSION [id] stdin=0"
cw -- sebastian -- bash -c 'echo "a b"; ls *'
check "arguments reach the bot word for word (spaces, quotes, globs)" log_has '[bash] [-c] [echo "a b"; ls *] stdin=0'
cw -- sebastian systemctl --user status
check "sebastian without -- is a usage error, nothing run" bash -c '[ "$1" -eq 2 ] && [ ! -s "$2" ]' _ "$rc" "$t/log"
cw -- sebastian --
check "sebastian -- with no command is a usage error, nothing run" bash -c '[ "$1" -eq 2 ] && [ ! -s "$2" ]' _ "$rc" "$t/log"
cw -- bogus
check "an unknown command is a usage error" test "$rc" -eq 2
check "the usage names the bot command" grep -q 'sebastian -- cmd' "$t/err"

# --- deploy: the committed tree, streamed, root's ---
cw -- deploy
check "deploy succeeds" test "$rc" -eq 0
check "deploy streams git archive of HEAD into a root bash in the guest (bytes on stdin, no file in /tmp)" \
  log_has "] [_] [/opt/vm-claw] [$REV] stdin=14"
check "  ... started as root from /" log_has 'limactl [shell] [--workdir] [/] [claw] [--] [sudo] [-n] [bash] [-c] [set -euo pipefail'
check "  ... and copies no file" bash -c '! grep -q "\[copy\]" "$1"' _ "$t/log"
check "deploy reports the commit" grep -qx "deploy: $REV at /opt/vm-claw in claw" "$t/out"
cw FAKE_DIRTY=' M README.md' -- deploy
check "a dirty tree is deployed as HEAD, with a note" grep -q 'uncommitted changes are not deployed' "$t/err"

# The deploy script itself, run here against a scratch /opt (FAKE_EXEC=1; chown is a fake).
rm -rf "$t/tree"; mkdir -p "$t/tree/provision"; echo '#!/bin/bash' > "$t/tree/provision/provision.sh"; echo new > "$t/tree/new-file"
rm -rf "$t/opt/vm-claw"; mkdir -p "$t/opt/vm-claw"; echo old > "$t/opt/vm-claw/old-file"
cw FAKE_EXEC=1 FAKE_TREE="$t/tree" FAKE_OPT="$t/opt" -- deploy
check "the deploy script swaps the new tree in" \
  bash -c '[ "$1" -eq 0 ] && [ -f "$2/vm-claw/provision/provision.sh" ] && [ -f "$2/vm-claw/new-file" ] && [ ! -e "$2/vm-claw/old-file" ]' _ "$rc" "$t/opt"
check "  ... stamps DEPLOYED with the commit" test "$(cat "$t/opt/vm-claw/DEPLOYED")" = "$REV"
check "  ... leaves no .new or .old behind" bash -c '[ ! -e "$1/vm-claw.new" ] && [ ! -e "$1/vm-claw.old" ]' _ "$t/opt"
check "  ... makes it root's and writable by no one else" \
  bash -c 'grep -q "^chown -R root:root .*/vm-claw.new$" "$1" && [ -z "$(find "$2/vm-claw" -perm -0020 -o -perm -0002 | head -1)" ]' _ "$t/log" "$t/opt"
rm -rf "$t/tree"; mkdir -p "$t/tree/docs"; echo x > "$t/tree/docs/x"
cw FAKE_EXEC=1 FAKE_TREE="$t/tree" FAKE_OPT="$t/opt" -- deploy
check "an archive without provision/provision.sh is refused" bash -c '[ "$1" -ne 0 ] && grep -q "empty or incomplete" "$2"' _ "$rc" "$t/err"
check "  ... and the deployed tree is untouched" bash -c '[ -f "$1/vm-claw/provision/provision.sh" ] && [ ! -e "$1/vm-claw.new" ]' _ "$t/opt"

# --- provision: deploy first, then provisioning from the deployed tree ---
cw -- provision
d=$(line_of "] [_] [/opt/vm-claw] [$REV] stdin=14")
r=$(line_of 'limactl [shell] [--workdir] [/] [claw] [--] [sudo] [-n] [rm] [-rf] [/opt/claw-provision] stdin=0')
p=$(line_of 'limactl [shell] [--workdir] [/] [claw] [--] [sudo] [-n] [bash] [/opt/vm-claw/provision/provision.sh] stdin=0')
check "provision deploys, removes the old staging copy, then runs provision.sh from /opt/vm-claw as root, in that order" \
  bash -c '[ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] && [ "$1" -lt "$2" ] && [ "$2" -lt "$3" ]' _ "$d" "$r" "$p"
check "  ... and stages nothing in the guest's /tmp" bash -c '! grep -q "/tmp/claw-provision" "$1"' _ "$t/log"
cw FAKE_LIMA_RC=1 -- provision
check "a failed deploy stops provision before provision.sh runs" \
  bash -c '[ "$1" -ne 0 ] && ! grep -q "provision/provision.sh\] stdin" "$2"' _ "$rc" "$t/log"

# --- tests/isolation-check.sh takes the instance from CLAW_INSTANCE too ---
iso() { : > "$t/log"; set +e; env -u CLAW_INSTANCE "$@" FAKE_LOG="$t/log" FAKE_LIMA_RC=1 LIMA_HOME="$t/lima" PATH="$t/bin:$PATH" bash "$repo/tests/isolation-check.sh" ${ISO_ARG:+"$ISO_ARG"} </dev/null >"$t/out" 2>"$t/err"; rc=$?; set -e; }
iso CLAW_INSTANCE=claw-drill
check "isolation-check probes CLAW_INSTANCE (and fails closed without its hostagent log)" \
  bash -c '[ "$1" -eq 1 ] && grep -q "^limactl \[shell\] \[claw-drill\]" "$2" && ! grep -q "^limactl \[shell\] \[claw\]" "$2"' _ "$rc" "$t/log"
ISO_ARG=claw-x iso CLAW_INSTANCE=claw-drill
check "an explicit instance argument still wins" bash -c 'grep -q "^limactl \[shell\] \[claw-x\]" "$1" && ! grep -q "\[claw-drill\]" "$1"' _ "$t/log"
for bad in 'bad name' 'x;y' '-x' 'Claw' '../claw'; do
  ISO_ARG="$bad" iso CLAW_INSTANCE=claw
  check "isolation-check refuses instance '$bad' before any limactl call" \
    bash -c '[ "$1" -eq 2 ] && [ ! -s "$2" ] && grep -q "is not an instance name" "$3"' _ "$rc" "$t/log" "$t/err"
done

echo "claw.sh tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
