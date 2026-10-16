# Bot User `sebastian` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the OpenClaw gateway, the agent's tools, the listener guard, the nightly backup and all bot data from the Lima guest's `admin` user (passwordless sudo) to a new unprivileged account `sebastian`, in place on the live guest, and fold in final-review findings I-1, I-3, I-4 and promoted minors #41 and #54.

**Architecture:** One sourced file, `provision/bot.sh`, names the bot account (UID/GID 2000, `/home/sebastian`), the deployed repo (`/opt/vm-claw`) and the `sudo -u sebastian env …` prefix that gives a command a user-session environment. Provisioning creates and asserts the account; `host/claw.sh` deploys a root-owned copy of the repo and reaches the bot with `sebastian -- <cmd>`. `migrate/import.sh` learns to restore an archive made by another home: it rewrites the old home prefix in structured configuration (`migrate/homepaths.mjs`), fails on any leftover in live configuration (`migrate/scan-refs.mjs --old-home`), and installs no `authorized_keys`. A new `migrate/rehome.sh` runs the in-place switch as fail-closed phases (`prepare | switch | verify | retire | rollback`); `host/pull-backups.sh` streams the bot's nights through `sudo -u sebastian tar`; `tests/acceptance.sh` runs as the bot and proves it has no root.

**Tech Stack:** bash (guest: bash 5 + GNU; host: macOS `/bin/bash` 3.2 + BSD) with shellcheck, Node 24 (`node:test`), systemd user units with linger, Lima 2.2 (`vz`), Tailscale, restic, launchd.

**Spec:** `docs/superpowers/specs/2026-10-02-bot-user-sebastian-design.md`, an addendum to `docs/superpowers/specs/2026-09-30-linux-vm-migration-design.md` (which still governs everything the addendum does not change). Final-review findings: `.superpowers/sdd/2026-09-30-linux-vm-migration/final-review.md` (local, not committed).

## Global Constraints

- The repo is public: never commit secrets, IPs, phone numbers, WhatsApp JIDs, account names, job IDs, tailnet names or key fragments. Scripts find things by pattern; docs use placeholders (`<host>`, `<lan-router-ip>`, `<owner-number>`, `<name>`). Documentation, loopback and RFC1918 example addresses only.
- Host scripts (`host/*.sh` and their tests) run under macOS `/bin/bash` 3.2 with BSD tools: no `mapfile`, no associative arrays, no `${var,,}`, no GNU-only flags. Guest scripts may use GNU tools, but every bash suite must also pass with `/bin/bash` 3.2 as the harness and first on PATH (`PATH="/bin:$PATH" /bin/bash <suite>`).
- Tests use fakes on PATH and scratch HOME/dirs only. No test touches the live guest, the appliance, the old VM, any gateway, the keychain, iCloud or `~/Backups`. Operational tasks name every live step and who runs it.
- Never run two gateways with the same WhatsApp credentials. `admin`'s gateway is proven `inactive` or `failed` before the bot's starts, and the bot's before `admin`'s restarts. Rehearsal and drill imports strip both WhatsApp credential sets and disable cron. A drill never runs `import.sh final`.
- `openclaw doctor --non-interactive` writes: run it only with the gateway stopped.
- Never run git inside the guest (the worktree's `.git` file does not resolve there). The guest gets the repo only through `host/claw.sh deploy` (a `git archive` of HEAD made on the host).
- Pins and floors from `provision/versions.env`, unchanged by this work: OpenClaw `2026.9.7` (a floor: provisioning never downgrades), node major `24`, wacli `0.13.0`, sag `0.4.0`, summarize `@steipete/summarize@0.21.6`.
- Bot account (spec §1): name `sebastian`, UID and GID `2000`, home `/home/sebastian` at mode 700, shell `/bin/bash`, password locked, member of its own group only, no `sudo` (provisioning asserts `sudo -l -U sebastian` grants nothing), linger enabled, no `authorized_keys`, `DenyUsers sebastian` in sshd, Tailscale `--operator=sebastian`. These values live once, in `provision/bot.sh`.
- `admin` (uid 501, gid 1000, home `/Users/admin`) stays Lima's login and maintenance user with passwordless sudo. After the switch it owns no bot data and no bot units, and its linger is disabled. Its own `~/.ssh/authorized_keys` stays.
- The deployed repo is `/opt/vm-claw`: root-owned, world-readable, writable by no one else. The bot runs scripts from there.
- Retired copy: `/var/lib/claw-retired-admin-<date>/`, root-owned at mode 700, deleted after 14 days.
- Non-goals (spec): no change to the Lima VM definition, the firewall rules or the port forward (guest `127.0.0.1:18789` → host `127.0.0.1:18789`); `admin`'s sudo is not restricted; chat transcripts and state databases are never rewritten (only live configuration); Tart retirement (old plan Task 14) is unchanged.
- `CLAW_INSTANCE` (default `claw`) selects the Lima instance in every host script; a value must match `^[a-z0-9][a-z0-9-]*$`.
- Scripts that run as the bot use `$HOME`; only `provision/bot.sh` names the bot's home.
- Every commit ends with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **The guard watching the wrong log after the in-place switch.** No reboot happens, so `/tmp/openclaw` is still `admin`'s: the bot's gateway logs elsewhere (or not at all) and the guard, which reads `/tmp/openclaw`, judges `admin`'s stale lines. Expected: the switch moves `admin`'s log dir aside before the bot's gateway starts, and acceptance fails when the guard's log dir is not the bot's. Pinned by Task 8 ("admin's gateway logs were set aside before the import (Review Focus 1)") and Task 7 ("…gateway log dir…: a log dir of another user -> FAIL").
2. **The switch importing a snapshot older than the downtime.** The switch's own nightly failed, or the newest night predates the switch, so hours of messages and sessions vanish without an error. Expected: refuse unless the nightly service ended in `success` and a night not older than the switch exists. Pinned by Task 8 ("a nightly that fails stops the switch", "a nightly that ends without success stops the switch", "a nightly older than the switch is never imported", each marked Review Focus 2).
3. **A rollback onto stale or mixed WhatsApp state.** `admin`'s gateway restarts on its pre-switch credentials, or the bot's `session.db` lands next to `admin`'s leftover `-wal`/`-shm`. Expected: `admin`'s `whatsapp*` and `session.db*` (with `-wal`/`-shm`) are moved aside, the bot's are copied over, and only then is `admin`'s gateway enabled. Pinned by Task 8 ("the bot's WhatsApp state is carried to admin before admin's gateway starts (Review Focus 3)", "… admin now has the bot's credentials and session, and none of its old -shm", "… admin's own set is kept aside, -shm included").
4. **Phases run out of order or twice under stress.** Retire before a passing verify, retire while the bot's gateway is down, a second switch over the bot's state, verify in the wrong mode. Expected: each refuses and names what to run. Pinned by Task 8 ("retire without a recorded pass is refused", "retire with the bot's gateway down is refused", "a second switch is refused", "verify before any switch is refused", "verify in the other mode is refused", each marked Review Focus 4).
5. **Checks on the bot's mode-700 home made as `admin` read as "absent".** A plain `[ -e ]` as `admin` fails for want of permission, so a switch could run over existing bot state and a check could pass vacuously. Expected: every look at the bot's files goes through `sudo` or runs as the bot. Pinned by Task 8 ("… and looked inside the bot's home through sudo" and "prepare refuses when the bot already has state, seen through sudo", both marked Review Focus 5), Task 5 ("the listing ran as the bot, over its backups dir", "each night was streamed by the bot's tar", "the stamp was written by the bot, through a temp file") and Task 2 (the `no SSH login keys for sebastian` FAIL case, marked Review Focus 5).

---

## File Structure

```
provision/bot.sh                      NEW  sourced: BOT_USER, BOT_UID, BOT_HOME, CLAW_REPO, BOT_SESSION (the env prefix)
host/claw.sh                          MOD  CLAW_INSTANCE; deploy (repo to /opt/vm-claw); provision from /opt/vm-claw; sebastian -- <cmd>
host/claw.test.sh                     NEW  fakes-only tests for claw.sh and isolation-check's instance default
tests/isolation-check.sh              MOD  instance defaults to CLAW_INSTANCE
Makefile                              MOD  make unit runs host/claw.test.sh and migrate/rehome.test.sh
provision/lib.sh                      MOD  assert <name> <check>: a state provisioning must find, never changes
provision/provision.sh                MOD  the bot account, sshd DenyUsers, persistent journal, Tailscale operator; no admin linger
tests/stack-check.sh                  MOD  bot-account, repo and Tailscale-operator lines; no admin linger line
tests/stack-check.test.sh             MOD  fakes for the new lines
migrate/homepaths.mjs                 NEW  old-home -> new-home rewrite of structured config (pure functions + CLI)
migrate/homepaths.test.mjs            NEW
migrate/scan-refs.mjs                 MOD  --old-home: leftover scan of live configuration
migrate/scan-refs.test.mjs            MOD
migrate/import.sh                     MOD  archive home from the restore layout; rewrite + scan; no authorized_keys across homes;
                                           refuses root and a missing user manager; Tailscale operator pre-flight; closing hint
migrate/import.test.sh                MOD
host/pull-backups.sh                  MOD  CLAW_INSTANCE; list, stream (tar) and stamp as the bot via sudo; stricter night gate
host/install.sh                       MOD  CLAW_INSTANCE into the plist and the status check
host/local.vm-claw.pull-backups.plist MOD  EnvironmentVariables CLAW_INSTANCE=@INSTANCE@
host/install.test.sh                  MOD
ops/backup/backup.test.sh             MOD  fake limactl streams as the bot; new pull tests; plist check
ops/listener-guard/guard.mjs          MOD  --now without --dry-run refuses (exit 2)
ops/listener-guard/fixtures/stranded-listener/openclaw-2026-09-30.log  NEW  committed stranded-listener log
ops/listener-guard/guard.cli.test.mjs MOD  clock-relative sandbox; refusal and fixture-replay tests
ops/listener-guard/guard.test.mjs     MOD  the fixture decides restart
tests/acceptance.sh                   MOD  runs as the bot: privilege items, guard replay and refusal, gateway log dir,
                                           memory paths, MANUAL lines, LAN address rejects 0.x and 127.x
tests/acceptance.test.sh              MOD
migrate/rehome.sh                     NEW  the in-place switch: prepare | switch | verify | retire | rollback
migrate/rehome.test.sh                NEW
README.md                             MOD  rewritten for the two-account layout; I-3, I-4, I-1
CLAUDE.md                             MOD  rewritten for the two-account layout
lima/claw.yaml                        MOD  comments only (the VM definition does not change)
docs/verification.md                  MOD  bot-account facts (Task 9); rehearsal, switch and retirement records (Tasks 10-12)
```

Task order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 (code and docs, each with a task review) → final review of `8f21db3..HEAD` → 10 (rehearsal) → 11 (production, owner) → 12 (retire, 14 days later).

Line references are to the files at `8f21db3`. Where a task edits one file in several places, apply its edits bottom-up, or match the quoted text.

Deliberate departures from the spec's wording (each is pinned by a test in its task):

- The guard replay accepts `skip: WhatsApp not linked (2 events)` in `rehearsal` mode: a drill has no WhatsApp link, and the guard asks for one before it restarts, so "not linked" is reached only after the replay found the stranded listener. `final` requires `restart: stranded listener (2 events)` (Task 7).
- The LAN-address check rejects all of `0.0.0.0/8` and `127.0.0.0/8`, not only `0.0.0.0` and `127.0.0.1` (Task 7).
- Rollback before `retire` also carries the bot's WhatsApp state back to admin, admin's own set moved aside first (I-3's rule), because the bot's gateway changed the credentials after the switch; the spec's "re-enable admin's three units" is still the core of it (Task 8).
- `retire` also moves admin's `~/.ssh` except `authorized_keys` (the vault deploy key is bot data, success criterion 3), the aside, stale and retired dirs of earlier imports, and the guard's state; the switch sets admin's `/tmp/openclaw` logs aside so the guard reads the bot's (Task 8).
- Acceptance adds two items: the guard's log dir belongs to the bot, and the memory index's paths are under the bot's home (spec Risks, "absolute paths OpenClaw stores elsewhere") (Task 7).
- `host/claw.sh provision` deploys `/opt/vm-claw` and runs provisioning from there; nothing root runs is staged in `/tmp`, which the bot can write (Task 1).
- The host pull keeps a night only when it holds exactly its three plain files, because the stream now comes from the bot's side of the guest (Task 5).

---

### Task 1: Bot constants and the host wrapper (`CLAW_INSTANCE`, `deploy`, `sebastian -- <cmd>`)

**Files:**
- Create: `provision/bot.sh`, `host/claw.test.sh`
- Modify: `host/claw.sh:1-28` (whole file), `tests/isolation-check.sh:4`, `Makefile:13-18`
- Test: `host/claw.test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `provision/bot.sh` (sourced): `BOT_USER=sebastian`, `BOT_UID=2000`, `BOT_HOME=/home/sebastian`, `CLAW_REPO=/opt/vm-claw`, and the array `BOT_SESSION=(sudo -n -u sebastian -- env -C /home/sebastian HOME=/home/sebastian USER=sebastian LOGNAME=sebastian XDG_RUNTIME_DIR=/run/user/2000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/2000/bus)`. `"${BOT_SESSION[@]}" <cmd…>` runs `<cmd>` as the bot from a sudo-capable account.
  - `host/claw.sh create [--memory GiB] | deploy | provision | start | stop | shell [-- cmd…] | sebastian -- cmd… | destroy`, instance `${CLAW_INSTANCE:-claw}` (must match `^[a-z0-9][a-z0-9-]*$`, else exit 2 before any `limactl` call).
  - `deploy`: `git archive --format=tar HEAD` on the host, piped into `limactl shell --workdir / <inst> -- sudo -n bash -c <script> _ /opt/vm-claw <commit>`; the guest tree is swapped in only when complete, `chown -R root:root`, `chmod -R u=rwX,go=rX`, with `/opt/vm-claw/DEPLOYED` holding the commit. Prints `deploy: <commit> at /opt/vm-claw in <inst>`.
  - `provision`: `deploy`, then `sudo -n rm -rf /opt/claw-provision`, then `sudo -n bash /opt/vm-claw/provision/provision.sh`.
  - `sebastian -- cmd…`: `limactl shell --workdir / <inst> -- "${BOT_SESSION[@]}" cmd…`.
  - `tests/isolation-check.sh [instance]`: instance defaults to `${CLAW_INSTANCE:-claw}`.

- [ ] **Step 1: Write the failing test**

Create `host/claw.test.sh`:

```bash
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

echo "claw.sh tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash host/claw.test.sh`
Expected: exit 1, ending `claw.sh tests: N passed, M failed` with M > 0, among them `FAIL: CLAW_INSTANCE picks the instance`, `FAIL: sebastian -- cmd: as the bot through sudo, …` and `FAIL: deploy succeeds`.

- [ ] **Step 3: Write `provision/bot.sh`**

```bash
#!/bin/bash
# Sourced, never run. The bot account of docs/superpowers/specs/2026-10-02-bot-user-sebastian-design.md, in one
# place for provisioning, the host wrapper, the backup pull, the in-place switch and the checks.
# shellcheck disable=SC2034  # every name here is used by the scripts that source this file
BOT_USER=sebastian
BOT_UID=2000
BOT_HOME=/home/sebastian
# The repo inside the guest: root-owned, readable by everyone, writable by no one else (host/claw.sh deploy).
CLAW_REPO=/opt/vm-claw
# A prefix that runs a command as the bot with a user-session environment, so systemctl --user, journalctl --user
# and openclaw reach the bot's own lingering user manager. Run it from an account with sudo (admin).
BOT_SESSION=(sudo -n -u "$BOT_USER" -- env -C "$BOT_HOME" HOME="$BOT_HOME" USER="$BOT_USER" LOGNAME="$BOT_USER"
  XDG_RUNTIME_DIR="/run/user/$BOT_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$BOT_UID/bus")
```

- [ ] **Step 4: Rewrite `host/claw.sh`**

```bash
#!/bin/bash
# Host-side wrapper around limactl. CLAW_INSTANCE (default claw) picks the instance, for drills and rebuilds.
#   create [--memory GiB]  a new instance from lima/claw.yaml (8 GiB by default)
#   deploy                 the committed tree (git archive HEAD) to /opt/vm-claw: root-owned, read-only for others
#   provision              deploy, then provisioning from /opt/vm-claw as root (idempotent)
#   start | stop | destroy
#   shell [-- cmd…]        a shell or a command as admin (Lima's login user, with sudo)
#   sebastian -- cmd…      a command as the bot account, with XDG_RUNTIME_DIR and the D-Bus address set
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=provision/bot.sh
. "$repo/provision/bot.sh"
inst="${CLAW_INSTANCE:-claw}"
usage() { echo "usage: [CLAW_INSTANCE=name] $0 create [--memory GiB] | deploy | provision | start | stop | shell [-- cmd…] | sebastian -- cmd… | destroy" >&2; exit 2; }
# A Lima instance name and nothing else: it lands in limactl arguments.
if ! [[ $inst =~ ^[a-z0-9][a-z0-9-]*$ ]]; then echo "claw.sh: CLAW_INSTANCE '$inst' is not an instance name (a-z, 0-9, -)" >&2; exit 2; fi

# Runs as root in the guest: $1 = the target dir, $2 = the commit. The archive arrives on stdin, never as a file in
# a directory the bot can write (/tmp), and the tree replaces the old one only once it is complete.
# shellcheck disable=SC2016  # expanded by the guest's bash, not here
deploy_script='set -euo pipefail
new="$1.new"; old="$1.old"
rm -rf "$new" "$old"; mkdir -m 755 "$new"
tar -xf - -C "$new"
if [ ! -f "$new/provision/provision.sh" ]; then echo "deploy: the archive is empty or incomplete (no provision/provision.sh)" >&2; rm -rf "$new"; exit 1; fi
printf "%s\n" "$2" > "$new/DEPLOYED"
chown -R root:root "$new"; chmod -R u=rwX,go=rX "$new"
if [ -e "$1" ]; then mv "$1" "$old"; fi
mv "$new" "$1"; rm -rf "$old"'

deploy() {
  local rev
  rev=$(git -C "$repo" rev-parse HEAD)
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then echo "claw.sh: note: uncommitted changes are not deployed (deploy ships HEAD $rev)" >&2; fi
  git -C "$repo" archive --format=tar HEAD | limactl shell --workdir / "$inst" -- sudo -n bash -c "$deploy_script" _ "$CLAW_REPO" "$rev"
  echo "deploy: $rev at $CLAW_REPO in $inst"
}

case "${1:-}" in
  create)
    mem=8
    if [ "${2:-}" = "--memory" ]; then mem="${3:-}"; [ -n "$mem" ] || usage; fi
    limactl create --name="$inst" --memory="$mem" --tty=false "$repo/lima/claw.yaml"
    ;;
  deploy) deploy ;;
  provision)
    deploy
    # The staging copy older versions of this script left; provisioning now runs from the deployed tree.
    limactl shell --workdir / "$inst" -- sudo -n rm -rf /opt/claw-provision
    limactl shell --workdir / "$inst" -- sudo -n bash "$CLAW_REPO/provision/provision.sh"
    ;;
  start)   limactl start "$inst" ;;
  stop)    limactl stop "$inst" ;;
  shell)
    shift
    if [ "${1:-}" = "--" ]; then shift; fi
    limactl shell "$inst" -- "$@"
    ;;
  sebastian)
    shift
    if [ "${1:-}" != "--" ]; then usage; fi
    shift
    if [ "$#" -eq 0 ]; then usage; fi
    limactl shell --workdir / "$inst" -- "${BOT_SESSION[@]}" "$@"
    ;;
  destroy) limactl delete --force "$inst" ;;
  *) usage ;;
esac
```

- [ ] **Step 5: Let `tests/isolation-check.sh` default to `CLAW_INSTANCE`**

Replace line 4, `inst="${1:-claw}"`, with:

```bash
inst="${1:-${CLAW_INSTANCE:-claw}}"
```

- [ ] **Step 6: Add the suite to `make unit`**

In `Makefile`, after the line `	@bash host/install.test.sh`, add:

```make
	@bash host/claw.test.sh
```

- [ ] **Step 7: Run the tests**

Run: `bash host/claw.test.sh && PATH="/bin:$PATH" /bin/bash host/claw.test.sh && make lint`
Expected: `claw.sh tests: 37 passed, 0 failed` twice, and shellcheck prints nothing.

- [ ] **Step 8: Commit**

```bash
git add provision/bot.sh host/claw.sh host/claw.test.sh tests/isolation-check.sh Makefile
git commit -m "feat(host): CLAW_INSTANCE, root-owned repo deploy, and claw.sh sebastian -- <cmd>" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Provision the bot account

**Files:**
- Modify: `provision/lib.sh:36-38` (add `assert` before `summary`), `provision/provision.sh:2`, `:10` (source `bot.sh`), `:124-125` (drop admin's linger), `:127` (new section before `summary`), `tests/stack-check.sh:1-27` (whole file), `tests/stack-check.test.sh:28-30` (new cases before the summary)
- Test: `tests/stack-check.test.sh`; integration on a scratch instance `claw-drill` on the dev Mac (Step 7)

**Interfaces:**
- Consumes: `provision/bot.sh` (`BOT_USER`, `BOT_UID`, `BOT_HOME`, `CLAW_REPO`) and `host/claw.sh provision|shell|sebastian|create|start|destroy` with `CLAW_INSTANCE` (Task 1).
- Produces:
  - `provision/lib.sh`: `assert <name> <check-command>`: prints `ok      <name>` and counts it, or prints `FAILED  <name> (assertion: …)` and exits 1. It never changes anything.
  - A provisioned guest with: group and user `sebastian` (2000:2000, `/home/sebastian` mode 700 `sebastian:sebastian`, `/bin/bash`, password locked, own group only), no sudo (asserted), no `authorized_keys` (asserted), `/etc/ssh/sshd_config.d/20-claw-bot.conf` = `DenyUsers sebastian`, linger for `sebastian`, `/var/log/journal`, and `tailscale set --operator=sebastian` when Tailscale is `Running`. Provisioning no longer enables linger for `admin`.
  - `tests/stack-check.sh` lines (labels used by Tasks 10-11): `bot sebastian is 2000:2000, /home/sebastian, /bin/bash`, `bot home mode 700, sebastian's`, `bot password locked`, `bot in its own group only`, `no sudo for sebastian`, `no SSH login keys for sebastian`, `sshd denies sebastian`, `linger sebastian`, `repo at /opt/vm-claw: root's, writable by no one else`, and `tailscale operator sebastian` (or `skip tailscale operator (Tailscale is <state>; …)` when not logged in).

- [ ] **Step 1: Write the failing tests**

In `tests/stack-check.test.sh`, insert before the line `echo "stack-check tests: $pass passed, $fail failed"`:

```bash
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
run_bot
for l in "$L_USER" "$L_HOME" "$L_PW" "$L_GROUP" "$L_SUDO" "$L_KEYS" "$L_SSHD" "$L_LINGER" "$L_TS"; do bot_ok "$l"; done
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
bot_fails "$L_SSHD" 'FAKE_SSHD=port 22'
bot_fails "$L_LINGER" FAKE_LINGER=no
bot_fails "$L_TS" FAKE_TS_OPERATOR=
run_bot FAKE_TS_STATE=NeedsLogin
want "a logged-out Tailscale skips the operator line and names the state" "$(grep '^skip tailscale operator' "$t/sc.out" || true)" 'Tailscale is NeedsLogin'
if [ ! -e /opt/vm-claw ]; then
  run_bot
  want "no deployed repo: the repo line FAILs" "$(grep 'repo at /opt/vm-claw' "$t/sc.out" || true)" "^FAIL repo at /opt/vm-claw: root's"
fi
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bash tests/stack-check.test.sh`
Expected: exit 1, with `FAIL: 'bot sebastian is 2000:2000, /home/sebastian, /bin/bash' should be ok` and the other new labels (stack-check has no such lines yet), and `FAIL: admin's linger is no longer a stack line`.

- [ ] **Step 3: Add `assert` to `provision/lib.sh`**

Insert before the line `summary() { echo "provision: changed=$CHANGED ok=$OK"; }`:

```bash
# assert <name> <check-command>: a state provisioning must find and never creates or removes (granting or taking
# away a privilege is a deliberate, manual act). Counts as ok, or stops the run.
assert() {
  local name="$1" check="$2"
  if bash -eo pipefail -c "$check" >/dev/null 2>&1; then OK=$((OK+1)); echo "ok      $name"; return; fi
  echo "FAILED  $name (assertion: provisioning does not change this; see the check in provision.sh)"; exit 1
}
```

- [ ] **Step 4: Provision the bot account in `provision/provision.sh`**

Replace line 2 with:

```bash
# Guest provisioning. Run as root from /opt/vm-claw/provision (host/claw.sh provision deploys it). Safe to re-run.
```

After line 10 (`. "$here/versions.env"`), add:

```bash
# shellcheck source=provision/bot.sh
. "$here/bot.sh"
```

Delete lines 124-125 (the `# --- user services run without a login session ---` comment and `step "linger $U" …`): `admin` no longer runs bot units, and after the switch its linger stays off.

Insert before the last line (`summary`):

```bash
# --- the bot account: unprivileged, no sudo, no SSH login, lingering (spec 2026-10-02 §1) ------------------
# admin stays Lima's login and maintenance user. The bot's ids must be free or already the bot's: a clash stops
# the run here, before anything is created.
for db in passwd group; do
  holder=$(getent "$db" "$BOT_UID" | cut -d: -f1 || true)
  if [ -n "$holder" ] && [ "$holder" != "$BOT_USER" ]; then echo "FAILED  bot account ($db id $BOT_UID belongs to '$holder')"; exit 1; fi
done
step "group $BOT_USER ($BOT_UID)" "[ \"\$(getent group $BOT_USER | cut -d: -f3)\" = $BOT_UID ]" "groupadd --gid $BOT_UID $BOT_USER"
step "user $BOT_USER ($BOT_UID:$BOT_UID, $BOT_HOME, /bin/bash)" \
  "[ \"\$(getent passwd $BOT_USER | cut -d: -f3,4,6,7)\" = $BOT_UID:$BOT_UID:$BOT_HOME:/bin/bash ]" \
  "useradd --uid $BOT_UID --gid $BOT_UID --no-user-group --home-dir $BOT_HOME --create-home --shell /bin/bash $BOT_USER"
step "home $BOT_HOME mode 700, $BOT_USER's" "[ \"\$(stat -c %a:%U:%G $BOT_HOME)\" = 700:$BOT_USER:$BOT_USER ]" \
  "chown $BOT_USER:$BOT_USER $BOT_HOME && chmod 700 $BOT_HOME"
step "password locked for $BOT_USER" "[ \"\$(passwd -S $BOT_USER | cut -d' ' -f2)\" = L ]" "usermod --lock $BOT_USER"
step "$BOT_USER in its own group only" "[ \"\$(id -Gn $BOT_USER)\" = $BOT_USER ]" "usermod -G '' $BOT_USER"
assert "no sudo for $BOT_USER" "out=\$(LC_ALL=C sudo -l -U $BOT_USER 2>&1 || true); grep -qF 'is not allowed to run sudo' <<<\"\$out\""
assert "no SSH login keys for $BOT_USER" "[ ! -e $BOT_HOME/.ssh/authorized_keys ] && [ ! -e $BOT_HOME/.ssh/authorized_keys2 ]"
# sshd -T prints the effective config; plain grep (not -q) so a long producer is never cut off by SIGPIPE.
step "sshd denies $BOT_USER" "sshd -T | grep -ix 'denyusers $BOT_USER'" \
  "printf 'DenyUsers %s\n' $BOT_USER > /etc/ssh/sshd_config.d/20-claw-bot.conf && sshd -t && systemctl reload ssh"
step "linger $BOT_USER" "loginctl show-user $BOT_USER -p Linger | grep -q yes" "loginctl enable-linger $BOT_USER"
# journalctl --user works for an account outside systemd-journal only when journald splits logs per user, which it
# does on persistent storage only.
step "persistent journal" "[ -d /var/log/journal ]" \
  "install -d -m 2755 -g systemd-journal /var/log/journal && systemd-tmpfiles --create --prefix /var/log/journal && systemctl restart systemd-journald"
# gateway.tailscale.mode=serve: the gateway holds its Serve claim itself, and refuses to start when the claim fails.
# Without root that needs the operator setting; tailscaled stays a root service. Set once Tailscale is logged in
# (a drill never is).
ts_state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true)
if [ "$ts_state" = Running ]; then
  step "tailscale operator $BOT_USER" "[ \"\$(tailscale debug prefs | jq -r '.OperatorUser // empty')\" = $BOT_USER ]" \
    "tailscale set --operator=$BOT_USER"
else
  echo "notice  tailscale operator: Tailscale is ${ts_state:-not running}; re-run provisioning after tailscale up"
fi
```

- [ ] **Step 5: Rewrite `tests/stack-check.sh`**

```bash
#!/bin/bash
# Guest-side, run as admin (it uses sudo -n): every pinned tool at or above its pin, the compat links, the bot
# account, the deployed repo and the Tailscale operator. Exits 1 on any FAIL.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=provision/versions.env
. "${VERSIONS_ENV:-$here/provision/versions.env}"
# shellcheck source=provision/vercmp.sh
. "$here/provision/vercmp.sh"
# shellcheck source=provision/bot.sh
. "$here/provision/bot.sh"
fail=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
chk "node $NODE_MAJOR"           "node --version | grep -q '^v$NODE_MAJOR\.'"
# OpenClaw updates itself (`openclaw update`), so the pin is a floor: at least the pin passes, and the
# installed version is shown. Older or unreadable fails.
oc=$(openclaw_installed_version || true)
if version_ge "$oc" "$OPENCLAW_VERSION"; then echo "ok   openclaw $oc (pin $OPENCLAW_VERSION)"
else echo "FAIL openclaw ${oc:-unreadable} (want at least $OPENCLAW_VERSION)"; fail=1; fi
chk "op"                         "op --version"
chk "tailscale"                  "tailscale version"
chk "wacli $WACLI_VERSION"       "wacli --version | grep -qF '$WACLI_VERSION'"
chk "sag $SAG_VERSION"           "sag --version 2>&1 | grep -qF '$SAG_VERSION'"
chk "chromium"                   "chromium --version"
chk "gh"                         "gh --version"
for b in node op wacli sag openclaw; do chk "compat /opt/homebrew/bin/$b" "[ -x /opt/homebrew/bin/$b ]"; done
chk "compat node@24"             "[ -x /opt/homebrew/opt/node@24/bin/node ]"
# The bot account (spec 2026-10-02 §1). Its home is mode 700: what is inside is looked at through sudo, never as
# admin directly, where a refused look would read as "absent".
chk "bot $BOT_USER is $BOT_UID:$BOT_UID, $BOT_HOME, /bin/bash" "[ \"\$(getent passwd $BOT_USER | cut -d: -f3,4,6,7)\" = '$BOT_UID:$BOT_UID:$BOT_HOME:/bin/bash' ]"
chk "bot home mode 700, $BOT_USER's" "[ \"\$(sudo -n stat -c %a:%U:%G $BOT_HOME)\" = '700:$BOT_USER:$BOT_USER' ]"
chk "bot password locked"        "[ \"\$(sudo -n passwd -S $BOT_USER | cut -d' ' -f2)\" = L ]"
chk "bot in its own group only"  "[ \"\$(id -Gn $BOT_USER)\" = $BOT_USER ]"
chk "no sudo for $BOT_USER"      "out=\$(LC_ALL=C sudo -n -l -U $BOT_USER 2>&1 || true); grep -qF 'is not allowed to run sudo' <<<\"\$out\""
chk "no SSH login keys for $BOT_USER" "sudo -n test ! -e $BOT_HOME/.ssh/authorized_keys"
chk "sshd denies $BOT_USER"      "sudo -n sshd -T 2>/dev/null | grep -ix 'denyusers $BOT_USER'"
chk "linger $BOT_USER"           "loginctl show-user $BOT_USER -p Linger | grep -q yes"
chk "repo at $CLAW_REPO: root's, writable by no one else" \
  "[ -f $CLAW_REPO/DEPLOYED ] && [ -z \"\$(find $CLAW_REPO \\( ! -user root -o -perm -0020 -o -perm -0002 \\) -print | head -1)\" ]"
ts_state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true)
if [ "$ts_state" = Running ]; then
  chk "tailscale operator $BOT_USER" "[ \"\$(sudo -n tailscale debug prefs | jq -r '.OperatorUser // empty')\" = $BOT_USER ]"
else
  echo "skip tailscale operator (Tailscale is ${ts_state:-not running}; provisioning sets it after tailscale up)"
fi
[ "$fail" -eq 0 ] && echo "stack: OK"
exit "$fail"
```

- [ ] **Step 6: Run the tests and lint**

Run: `bash tests/stack-check.test.sh && PATH="/bin:$PATH" /bin/bash tests/stack-check.test.sh && make lint`
Expected: `stack-check tests: 31 passed, 0 failed` twice on a machine without `/opt/vm-claw` (7 openclaw cases, 9 healthy bot lines, 1 no-admin-linger, 12 failing cases, 1 skip, 1 missing repo; 30 where `/opt/vm-claw` exists), and no shellcheck output.

- [ ] **Step 7: Commit, then prove it on a scratch instance (dev Mac, ~20 min, no owner)**

```bash
git add provision/lib.sh provision/provision.sh tests/stack-check.sh tests/stack-check.test.sh
git commit -m "feat(provision): unprivileged bot account sebastian, sshd DenyUsers, Tailscale operator" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

`deploy` ships HEAD, so this runs after the commit. On the dev Mac (never the appliance; nothing live is touched):

```bash
export CLAW_INSTANCE=claw-drill
host/claw.sh create --memory 4 && host/claw.sh start
host/claw.sh provision 2>&1 | tail -25
host/claw.sh provision 2>&1 | tail -3
host/claw.sh shell -- bash /opt/vm-claw/tests/stack-check.sh
host/claw.sh sebastian -- id
host/claw.sh sebastian -- systemctl --user is-system-running
host/claw.sh sebastian -- sudo -n true; echo "rc=$?"
host/claw.sh shell -- sudo -n sshd -T | grep -i denyusers
host/claw.sh destroy; unset CLAW_INSTANCE
```

Expected, in order: `deploy: <sha> at /opt/vm-claw in claw-drill`; the first provision lists `change  group sebastian (2000)`, `change  user sebastian …`, `ok      no sudo for sebastian`, `ok      no SSH login keys for sebastian`, `change  sshd denies sebastian`, `change  linger sebastian`, `notice  tailscale operator: Tailscale is NeedsLogin…` and ends `provision: changed=N ok=M` with no `FAILED`; the second ends `provision: changed=0 ok=…`; stack-check prints every bot line `ok`, `skip tailscale operator (Tailscale is NeedsLogin; …)` and `stack: OK`; `uid=2000(sebastian) gid=2000(sebastian) groups=2000(sebastian)`; `running` (or `degraded`); `sudo: a password is required` and `rc=1`; `denyusers sebastian`. If `deploy` reports an empty archive, `limactl shell` did not pass stdin through: stop and report it (do not stage the archive in the guest's `/tmp`, which the bot can write).

---

### Task 3: Home-path rewrite and leftover scan (Node)

**Files:**
- Create: `migrate/homepaths.mjs`, `migrate/homepaths.test.mjs`
- Modify: `migrate/scan-refs.mjs:20` (add `homeRefs` after `scan`), `:30-46` (the `--old-home` CLI branch), `migrate/scan-refs.test.mjs:1-6` (imports) and append tests
- Test: `migrate/homepaths.test.mjs`, `migrate/scan-refs.test.mjs` (both picked up by `make unit`'s `find migrate ops -name '*.test.mjs'`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `migrate/homepaths.mjs` exports `rehomeString(s, from, to) -> { text, count }`, `rehomeJson(value, from, to) -> { value, count }` (keys and string values, any depth), `validHomes(from, to) -> boolean`, `liveRoots(home) -> { json: string[], text: string[] }`, `JSON_ROOTS = [".openclaw/openclaw.json", ".openclaw/cron", ".openclaw/skills", "ops", "brain"]` (plus every `.openclaw/workspace*/skills` at run time), `TEXT_FILES = [".openclaw/bin/op-nosym", ".ssh/config", "brain/vault/.git/config"]`.
  - CLI `node migrate/homepaths.mjs <old-home> <new-home>`: rewrites in place under `<new-home>` (only files that change; modes kept), prints `homepaths: <file>: <n> path(s)` per file, `homepaths: <file>: not valid JSON, left for the scan`, and `homepaths: <N> file(s) rewritten from <old> to <new>`; exit 0, or 2 on bad homes.
  - `migrate/scan-refs.mjs` exports `homeRefs(text, oldHome, allow = []) -> number`; CLI `node migrate/scan-refs.mjs --old-home <abs-path> <file|dir>...`: explicit files are always scanned, directories are walked as today (`*.md|mjs|js|sh|json|txt`, skipping `node_modules`, `.git`, `vault`; so `*.jsonl` transcripts are never read), missing paths are skipped, `SCAN_ALLOW` applies; prints `<file>: <n> reference(s) to <old>` and `scan-refs: <N> file(s) still name <old>`; exit 1 if N > 0, 2 on bad usage. The existing macOS/Homebrew mode is unchanged.

- [ ] **Step 1: Write the failing tests**

Create `migrate/homepaths.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { rehomeString, rehomeJson, validHomes, JSON_ROOTS, TEXT_FILES } from "./homepaths.mjs";

const __dir = path.dirname(fileURLToPath(import.meta.url));
const O = "/Users/admin", N = "/home/sebastian";
const re = (s) => rehomeString(s, O, N);

test("the home itself, alone or as a prefix, becomes the new home", () => {
  assert.deepEqual(re("/Users/admin"), { text: "/home/sebastian", count: 1 });
  assert.deepEqual(re("/Users/admin/"), { text: "/home/sebastian/", count: 1 });
  assert.deepEqual(re("/Users/admin/.openclaw/bin/op-nosym"), { text: "/home/sebastian/.openclaw/bin/op-nosym", count: 1 });
});

test("paths that only look alike are left alone", () => {
  for (const s of ["/Users/administrator/x", "/Users/admin2", "/Users/admin.bak", "/Users/admin-old/x", "/x/Users/admin/y", "relative/Users/admin", "~/Users/admin"]) {
    assert.deepEqual(re(s), { text: s, count: 0 }, s);
  }
});

test("embedded paths in commands, assignments, lists and file URLs are rewritten, each one", () => {
  assert.deepEqual(re("sh -lc 'node /Users/admin/brain/h.mjs && cat /Users/admin/x'"),
    { text: "sh -lc 'node /home/sebastian/brain/h.mjs && cat /home/sebastian/x'", count: 2 });
  assert.equal(re("PATH=/Users/admin/bin:/Users/admin/.local/bin:/usr/bin").text, "PATH=/home/sebastian/bin:/home/sebastian/.local/bin:/usr/bin");
  assert.equal(re("file:///Users/admin/notes/a.md").text, "file:///home/sebastian/notes/a.md");
  assert.equal(re('{"dir":"/Users/admin/q"}').text, '{"dir":"/home/sebastian/q"}');
  assert.equal(re("Host vault\n  IdentityFile /Users/admin/.ssh/key\n").text, "Host vault\n  IdentityFile /home/sebastian/.ssh/key\n");
});

test("JSON: string values and keys at any depth; other values untouched", () => {
  const cfg = {
    secrets: { providers: { op: { source: "exec", command: `${O}/.openclaw/bin/op-nosym`, trustedDirs: [`${O}/.openclaw/bin`, "/usr/bin"], timeoutMs: 5000, enabled: true, extra: null } } },
    agents: { defaults: { workspace: `${O}/.openclaw/workspace` } },
    installs: { [`${O}/.openclaw/extensions/x`]: { at: 1 } },
    note: "/Users/administrator stays",
  };
  const { value, count } = rehomeJson(structuredClone(cfg), O, N);
  assert.equal(count, 4);
  assert.equal(value.secrets.providers.op.command, `${N}/.openclaw/bin/op-nosym`);
  assert.deepEqual(value.secrets.providers.op.trustedDirs, [`${N}/.openclaw/bin`, "/usr/bin"]);
  assert.equal(value.secrets.providers.op.timeoutMs, 5000);
  assert.equal(value.secrets.providers.op.enabled, true);
  assert.equal(value.secrets.providers.op.extra, null);
  assert.equal(value.agents.defaults.workspace, `${N}/.openclaw/workspace`);
  assert.deepEqual(Object.keys(value.installs), [`${N}/.openclaw/extensions/x`]);
  assert.equal(value.note, "/Users/administrator stays");
});

test("idempotent: a second pass finds nothing", () => {
  const once = rehomeJson({ a: `${O}/x`, b: [O] }, O, N).value;
  assert.deepEqual(rehomeJson(structuredClone(once), O, N), { value: once, count: 0 });
});

test("homes must be absolute, different and not nested", () => {
  assert.equal(validHomes(O, N), true);
  for (const [a, b] of [[O, O], ["Users/admin", N], [O, "home/sebastian"], [O, `${O}/sub`], [`${N}/sub`, N], [O, "/home/../x"], [O, "/home/sebastian/"], [undefined, N]]) {
    assert.equal(validHomes(a, b), false, `${a} -> ${b}`);
  }
});

test("the roots are the spec's live configuration", () => {
  assert.deepEqual(JSON_ROOTS, [".openclaw/openclaw.json", ".openclaw/cron", ".openclaw/skills", "ops", "brain"]);
  assert.deepEqual(TEXT_FILES, [".openclaw/bin/op-nosym", ".ssh/config", "brain/vault/.git/config"]);
});

function fixtureHome() {
  const h = fs.mkdtempSync(path.join(os.tmpdir(), "homepaths-"));
  const w = (rel, body, mode = 0o600) => { const f = path.join(h, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, body); fs.chmodSync(f, mode); return f; };
  const files = {
    config: w(".openclaw/openclaw.json", JSON.stringify({ secrets: { providers: { op: { command: `${O}/.openclaw/bin/op-nosym`, trustedDirs: [`${O}/.openclaw/bin`] } } }, agents: { defaults: { workspace: `${O}/.openclaw/workspace` } } }, null, 2) + "\n"),
    jobs: w(".openclaw/cron/jobs.json", JSON.stringify({ jobs: [{ id: "j1", payload: { kind: "command", argv: ["/usr/bin/node", `${O}/brain/harvester/harvest.mjs`] } }] }) + "\n"),
    skill: w(".openclaw/workspace-vera/skills/s/config.json", JSON.stringify({ dir: `${O}/brain/queue` }) + "\n"),
    ops: w("ops/bench/cfg.json", JSON.stringify({ out: `${O}/backups` }) + "\n"),
    harvester: w("brain/harvester/config.json", JSON.stringify({ storeDb: `${O}/.wacli/wacli.db` }) + "\n"),
    clean: w("brain/harvester/other.json", '{ "same": "bytes", "x": 1 }\n'),
    wrapper: w(".openclaw/bin/op-nosym", `#!/bin/sh\n# from ${O}/.openclaw/bin\nexec /usr/bin/op "$@"\n`, 0o755),
    sshcfg: w(".ssh/config", `Host vault\n  IdentityFile ${O}/.ssh/ocsb_vault\n`),
    gitcfg: w("brain/vault/.git/config", `[core]\n\tsshCommand = ssh -i ${O}/.ssh/ocsb_vault\n`),
    modules: w("brain/harvester/node_modules/x/package.json", JSON.stringify({ path: `${O}/x` })),
    vaultJson: w("brain/vault/notes.json", JSON.stringify({ path: `${O}/x` })),
    transcript: w(".openclaw/agents/main/sessions/s.jsonl", JSON.stringify({ text: `ls ${O}/brain` }) + "\n"),
    agentJson: w(".openclaw/agents/main/agent/models.json", JSON.stringify({ path: `${O}/x` })),
    broken: w("brain/queue/bad.json", `{"cut off": "${O}/x`),
  };
  return { h, files };
}
const run = (...args) => spawnSync(process.execPath, [path.join(__dir, "homepaths.mjs"), ...args], { encoding: "utf8" });

test("CLI: rewrites the live config under the new home, and nothing else", (t) => {
  const { h, files } = fixtureHome();
  t.after(() => fs.rmSync(h, { recursive: true, force: true }));
  const before = Object.fromEntries(Object.entries(files).map(([k, f]) => [k, fs.readFileSync(f, "utf8")]));
  const r = run(O, h);
  assert.equal(r.status, 0, r.stderr);
  const now = (k) => fs.readFileSync(files[k], "utf8");
  for (const k of ["config", "jobs", "skill", "ops", "harvester", "wrapper", "sshcfg", "gitcfg"]) {
    assert.ok(!now(k).includes(O), `${k} still names ${O}`);
    assert.ok(now(k).includes(h), `${k} names the new home`);
  }
  assert.equal(JSON.parse(now("config")).secrets.providers.op.command, `${h}/.openclaw/bin/op-nosym`);
  assert.deepEqual(JSON.parse(now("jobs")).jobs[0].payload.argv, ["/usr/bin/node", `${h}/brain/harvester/harvest.mjs`]);
  for (const k of ["clean", "modules", "vaultJson", "transcript", "agentJson", "broken"]) assert.equal(now(k), before[k], `${k} must be byte-identical`);
  assert.match(r.stdout, /bad\.json: not valid JSON, left for the scan/);
  assert.match(r.stdout, /homepaths: 8 file\(s\) rewritten from \/Users\/admin to /);
  assert.equal(fs.statSync(files.config).mode & 0o777, 0o600);
  assert.equal(fs.statSync(files.wrapper).mode & 0o777, 0o755);
  const again = run(O, h);
  assert.equal(again.status, 0);
  assert.match(again.stdout, /homepaths: 0 file\(s\) rewritten/);
});

test("CLI: bad homes are a usage error and change nothing", (t) => {
  const { h, files } = fixtureHome();
  t.after(() => fs.rmSync(h, { recursive: true, force: true }));
  const before = fs.readFileSync(files.config, "utf8");
  for (const args of [[], [O], [O, O], ["Users/admin", h], [h, `${h}/sub`]]) {
    const r = run(...args);
    assert.equal(r.status, 2, JSON.stringify(args));
    assert.match(r.stderr, /usage: homepaths\.mjs/);
  }
  assert.equal(fs.readFileSync(files.config, "utf8"), before);
});
```

In `migrate/scan-refs.test.mjs`, replace the import block (lines 1-6) with:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { scan, homeRefs } from "./scan-refs.mjs";
```

and append:

```js
test("homeRefs counts the old home wherever it is still named, lookalikes excluded", () => {
  assert.equal(homeRefs("cd /Users/admin/brain && ls /Users/admin", "/Users/admin"), 2);
  assert.equal(homeRefs("see /Users/admin.", "/Users/admin"), 1);
  assert.equal(homeRefs("file:///Users/admin/x", "/Users/admin"), 1);
  assert.equal(homeRefs("/Users/administrator /Users/admin-old /Users/admin2", "/Users/admin"), 0);
  assert.equal(homeRefs("", "/Users/admin"), 0);
});

test("homeRefs honours the allow-list", () => {
  assert.equal(homeRefs("historical: lived in /Users/admin\nnow: /Users/admin/x", "/Users/admin", [/^historical:/]), 1);
});

const scanDir = () => fs.mkdtempSync(path.join(os.tmpdir(), "scan-home-"));
const put = (d, rel, body) => { const f = path.join(d, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, body); return f; };
const runScan = (...args) => spawnSync(process.execPath, [path.join(__dir, "scan-refs.mjs"), ...args], { encoding: "utf8" });

test("--old-home CLI: names each file that still has it, skips transcripts and the vault, scans explicit files whatever their name", (t) => {
  const d = scanDir();
  t.after(() => fs.rmSync(d, { recursive: true, force: true }));
  put(d, "brain/prompts/p.md", "Read /Users/admin/brain/queue first.\n");
  put(d, "brain/ok.md", "Read ~/brain/queue first.\n");
  put(d, "brain/sessions.jsonl", '{"t":"/Users/admin/x"}\n');
  put(d, "brain/vault/note.md", "/Users/admin/old\n");
  put(d, "brain/node_modules/m/index.js", "/Users/admin\n");
  const wrapper = put(d, "bin/op-nosym", "# /Users/admin/.openclaw/bin\n");
  const r = runScan("--old-home", "/Users/admin", path.join(d, "brain"), wrapper, path.join(d, "absent"));
  assert.equal(r.status, 1);
  assert.match(r.stdout, /brain\/prompts\/p\.md: 1 reference\(s\) to \/Users\/admin/);
  assert.match(r.stdout, /bin\/op-nosym: 1 reference\(s\) to \/Users\/admin/);
  assert.doesNotMatch(r.stdout, /ok\.md|sessions\.jsonl|vault|node_modules/);
  assert.match(r.stdout, /scan-refs: 2 file\(s\) still name \/Users\/admin/);
});

test("--old-home CLI: clean roots exit 0; a missing or relative home is a usage error", (t) => {
  const d = scanDir();
  t.after(() => fs.rmSync(d, { recursive: true, force: true }));
  put(d, "brain/ok.md", "Read ~/brain/queue first.\n");
  const ok = runScan("--old-home", "/Users/admin", path.join(d, "brain"));
  assert.equal(ok.status, 0);
  assert.match(ok.stdout, /scan-refs: 0 file\(s\) still name \/Users\/admin/);
  for (const args of [["--old-home"], ["--old-home", "Users/admin", d]]) {
    const r = runScan(...args);
    assert.equal(r.status, 2, JSON.stringify(args));
    assert.match(r.stderr, /usage: scan-refs\.mjs --old-home/);
  }
});
```

- [ ] **Step 2: Run them to verify they fail**

Run: `node --test migrate/homepaths.test.mjs migrate/scan-refs.test.mjs`
Expected: FAIL: `homepaths.test.mjs` cannot load (`Cannot find module …/migrate/homepaths.mjs`), and `scan-refs.test.mjs` fails with `SyntaxError: The requested module './scan-refs.mjs' does not provide an export named 'homeRefs'`.

- [ ] **Step 3: Implement `migrate/homepaths.mjs`**

```js
#!/usr/bin/env node
// Rewrite the archive's home (e.g. /Users/admin) to the importing account's home in the structured configuration a
// restore carries over: docs/superpowers/specs/2026-10-02-bot-user-sebastian-design.md §2 step 4. JSON files are
// rewritten structurally, keys and string values alike; a few non-JSON config files are rewritten as text. Only the
// home itself is replaced: a path that merely starts with the same letters (/Users/administrator, /Users/admin.bak,
// /x/Users/admin) is left alone. Transcripts (*.jsonl) and databases are never touched.
// migrate/scan-refs.mjs --old-home then fails on anything still left in live configuration.
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

// Relative to the home. Directories are walked for *.json; node_modules, .git and vault are skipped. Every
// .openclaw/workspace*/skills directory is added at run time.
export const JSON_ROOTS = [".openclaw/openclaw.json", ".openclaw/cron", ".openclaw/skills", "ops", "brain"];
export const TEXT_FILES = [".openclaw/bin/op-nosym", ".ssh/config", "brain/vault/.git/config"];
const SKIP_DIRS = new Set(["node_modules", ".git", "vault"]);

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
// The home as a whole path: at the start, after a character that cannot be part of a path (space, quote, =, :,
// comma, brackets, a newline), or right after file://; and followed by /, the end, or such a character.
const homeRe = (from) => new RegExp(`(^|[^\\w.~/-]|file://)${esc(from)}(?=/|$|[^\\w.-])`, "g");

export function rehomeString(s, from, to) {
  let count = 0;
  const text = s.replace(homeRe(from), (_m, pre) => { count++; return pre + to; });
  return { text, count };
}

export function rehomeJson(value, from, to) {
  let count = 0;
  const walk = (v) => {
    if (typeof v === "string") { const r = rehomeString(v, from, to); count += r.count; return r.text; }
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === "object") {
      const out = {};
      for (const [k, x] of Object.entries(v)) { const rk = rehomeString(k, from, to); count += rk.count; out[rk.text] = walk(x); }
      return out;
    }
    return v;
  };
  return { value: walk(value), count };
}

// Both absolute, different, and neither inside the other (a rewrite into a subdirectory of the old home would match
// its own output on a second run).
export function validHomes(from, to) {
  const abs = (p) => typeof p === "string" && /^\/[^\0]*[^/]$/.test(p) && !p.split("/").includes("..");
  return abs(from) && abs(to) && from !== to && !to.startsWith(from + "/") && !from.startsWith(to + "/");
}

export function liveRoots(home) {
  let ws = [];
  try { ws = fs.readdirSync(path.join(home, ".openclaw")).filter((n) => n.startsWith("workspace")).map((n) => `.openclaw/${n}/skills`); } catch { /* no state dir */ }
  return { json: [...JSON_ROOTS, ...ws].map((r) => path.join(home, r)), text: TEXT_FILES.map((r) => path.join(home, r)) };
}

function* jsonFiles(p) {
  let st;
  try { st = fs.lstatSync(p); } catch { return; }
  if (st.isSymbolicLink()) return;
  if (st.isFile()) { if (p.endsWith(".json")) yield p; return; }
  if (!st.isDirectory()) return;
  for (const e of fs.readdirSync(p).sort()) if (!SKIP_DIRS.has(e)) yield* jsonFiles(path.join(p, e));
}

const isMain = Boolean(process.argv[1]) && import.meta.url === pathToFileURL(fs.realpathSync(process.argv[1])).href;
if (isMain) {
  const [from, to] = process.argv.slice(2);
  if (!validHomes(from, to)) {
    console.error("usage: homepaths.mjs <old-home> <new-home>   (two different absolute homes, neither inside the other)");
    process.exit(2);
  }
  const { json, text } = liveRoots(to);
  let files = 0;
  for (const root of json) {
    for (const f of jsonFiles(root)) {
      let cfg;
      try { cfg = JSON.parse(fs.readFileSync(f, "utf8")); } catch { console.log(`homepaths: ${f}: not valid JSON, left for the scan`); continue; }
      const { value, count } = rehomeJson(cfg, from, to);
      if (!count) continue;
      fs.writeFileSync(f, JSON.stringify(value, null, 2) + "\n");
      files++;
      console.log(`homepaths: ${f}: ${count} path(s)`);
    }
  }
  for (const f of text) {
    let st;
    try { st = fs.lstatSync(f); } catch { continue; }
    if (!st.isFile()) continue;
    const { text: out, count } = rehomeString(fs.readFileSync(f, "utf8"), from, to);
    if (!count) continue;
    fs.writeFileSync(f, out);
    files++;
    console.log(`homepaths: ${f}: ${count} path(s)`);
  }
  console.log(`homepaths: ${files} file(s) rewritten from ${from} to ${to}`);
}
```

- [ ] **Step 4: Extend `migrate/scan-refs.mjs`**

After the `scan` function (line 20), add:

```js
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
// --old-home: how often a file still names the archive's home. Counted on the raw text and broader than
// homepaths.mjs on purpose (any occurrence not followed by a name character: /Users/admin. and file:///Users/admin
// count), so whatever the rewrite leaves alone fails closed. Allow-listed lines (SCAN_ALLOW) are skipped.
export function homeRefs(text, oldHome, allow = []) {
  const body = text.split("\n").filter((l) => !allow.some((re) => re.test(l))).join("\n");
  return (body.match(new RegExp(`${esc(oldHome)}(?![\\w-])`, "g")) ?? []).length;
}
```

In the `if (isMain) {` block, insert right after the `allow` assignment (lines 33-34, ending `.map((l) => new RegExp(l)) : [];`):

```js
  const args = process.argv.slice(2);
  if (args[0] === "--old-home") {
    const old = args[1];
    if (!old || !old.startsWith("/") || old.length < 2) { console.error("usage: scan-refs.mjs --old-home <absolute-path> <file|dir>..."); process.exit(2); }
    let bad = 0;
    for (const p of args.slice(2)) {
      let st;
      try { st = fs.statSync(p); } catch { continue; }
      for (const f of st.isDirectory() ? files(p) : [p]) {
        const n = homeRefs(fs.readFileSync(f, "utf8"), old, allow);
        if (n) { bad++; console.log(`${f}: ${n} reference(s) to ${old}`); }
      }
    }
    console.log(`scan-refs: ${bad} file(s) still name ${old}`);
    process.exit(bad ? 1 : 0);
  }
```

- [ ] **Step 5: Run the tests**

Run: `node --test migrate/homepaths.test.mjs migrate/scan-refs.test.mjs migrate/binpaths.test.mjs migrate/cli.test.mjs`
Expected: PASS, `ℹ tests 37`, `ℹ fail 0`.

- [ ] **Step 6: Prove the tests bite**

Temporarily change `homeRe`'s lookahead `(?=/|$|[^\\w.-])` to `(?=)` and run `node --test migrate/homepaths.test.mjs`: "paths that only look alike are left alone" must FAIL. Restore it. Temporarily drop `"vault"` from `SKIP_DIRS`: the CLI test must FAIL (`vaultJson` rewritten). Restore it.

- [ ] **Step 7: Commit**

```bash
git add migrate/homepaths.mjs migrate/homepaths.test.mjs migrate/scan-refs.mjs migrate/scan-refs.test.mjs
git commit -m "feat(migrate): rewrite an archive's home in live config; scan for leftovers" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `import.sh` restores another home's archive into the bot account

**Files:**
- Modify: `migrate/import.sh:6` (header), `:54` (pre-flight after the command loop), `:58` (repo files), `:106-109` (Tailscale operator), `:130-136` (restore layout, archive home), `:164-171` (file state), `:185` (rewrite and scan after the residue check), `:272-273` (re-scan, closing hint)
- Modify: `migrate/import.test.sh:116-118` (fake restore), `:134-142` (fake systemctl), `:160` (fake npm), `:165-169` (fake tailscale), `:176` (fake id before the chmod), `:230` (`fresh`), and new tests before the line `# ===== Part 3: export.sh against a fake home ===…`
- Test: `migrate/import.test.sh`

**Interfaces:**
- Consumes: `migrate/homepaths.mjs <old-home> <new-home>` and `migrate/scan-refs.mjs --old-home <path> <file|dir>...` (Task 3).
- Produces (used by Task 8 and the runbook):
  - `import.sh rehearsal|final|drill <dir> [--force]`, run as the bot through `host/claw.sh sebastian -- bash /opt/vm-claw/migrate/import.sh …` or `"${BOT_SESSION[@]}" bash …`.
  - It reads the archive's home from the restore layout (`<target>/<root>/payload/posix<home>/.openclaw`, exactly one) and prints `import: the archive comes from <old>; its paths move to <home>` when it differs from `$HOME`; then it rewrites (homepaths), scans (fails with `the live configuration still names <old> …` before npm ci, the token or the gateway), re-scans after doctor, and installs no `.ssh/authorized_keys*`.
  - It refuses root (`… not as root`), a missing user manager (`no systemd user manager for <user> …`), a home that already has `authorized_keys` when the archive comes from another home (`… must have no SSH login …`), and, for `final` with `gateway.tailscale.mode` `serve|funnel`, a Tailscale operator other than the importing user (`Tailscale's operator must be <user>, not '<op>' …`).
  - Closing line: `import: done (<mode>). Now run tests/acceptance.sh <final|rehearsal> <lan-ip>` (`drill` and `rehearsal` both point at `rehearsal`).

- [ ] **Step 1: Teach the fakes the new cases**

In `migrate/import.test.sh`:

Replace the fake restore (lines 116-118) with:

```bash
  "backup restore")
    # The archive's original home decides the layout (FAKE_ARCHIVE_HOME; default: the importing home).
    root="$5/2026-01-01T00-00-00-openclaw-backup/payload/posix${FAKE_ARCHIVE_HOME:-$H}"
    mkdir -p "$root" && tar -xzf "$3" -C "$root"
    if [ -n "${FAKE_RESTORE_TWICE:-}" ]; then mkdir -p "$5/2026-01-01T00-00-00-openclaw-backup/payload/posix/srv/other/.openclaw"; fi ;;
```

In the fake `systemctl`, add this case line right after `case "$*" in`:

```bash
  "--user show-environment") [ -z "${FAKE_NO_MANAGER:-}" ] || { echo "Failed to connect to bus: No medium found" >&2; exit 1; } ;;
```

Replace the fake `npm`'s `echo` line (line 160) with (an `oldhome=` count of live config still naming `/Users/admin`, before `token=`):

```bash
echo "npm $* oldhome=$(grep -rlE '/Users/admin([^a-z0-9]|$)' "$H/.openclaw/openclaw.json" "$H/.openclaw/cron" "$H/brain" "$H/ops" "$H/.ssh" 2>/dev/null | wc -l | tr -d ' ') token=${OP_SERVICE_ACCOUNT_TOKEN:+set} cron_off=$([ -e "$H/.openclaw/cron-off" ] && echo yes || echo no) wa=$(find "$H/.openclaw/credentials" "$H"/.openclaw-stale-*/credentials "$H/.wacli" \( -name 'whatsapp*' -o -name 'session.db*' \) 2>/dev/null | wc -l | tr -d ' ')" >> "$FAKE_LOG"
```

Replace the fake `tailscale` (lines 165-169) with:

```bash
cat > "$t/bin/tailscale" <<'EOF'
#!/bin/bash
echo "tailscale $*" >> "$FAKE_LOG"
if [ "$1 ${2:-}" = "debug prefs" ]; then echo "{\"OperatorUser\":\"${FAKE_TS_OPERATOR-$(id -un)}\"}"; exit 0; fi
echo "{\"BackendState\":\"${FAKE_TS_STATE:-NeedsLogin}\"}"
EOF
```

Before `chmod +x "$t/bin/"*` (line 176), add a fake `id`:

```bash
cat > "$t/bin/id" <<'EOF'
#!/bin/bash
if [ "$*" = "-u" ] && [ -n "${FAKE_UID:-}" ]; then echo "$FAKE_UID"; exit 0; fi
exec /usr/bin/id "$@"
EOF
```

In `fresh()` (line 230), add `FAKE_ARCHIVE_HOME FAKE_RESTORE_TWICE FAKE_NO_MANAGER FAKE_UID FAKE_TS_OPERATOR` to the `unset` list.

- [ ] **Step 2: Write the failing tests**

Insert before the line `# ===== Part 3: export.sh against a fake home ===…`:

```bash
# ===== Part 2b: an archive from another home: the in-place move to the bot account (spec 2026-10-02 §2) ==========
mkold() { # mkold <dir> [leftover]: a nightly made by /Users/admin whose live config names that home throughout
  local d="$1" s="$1/src" O=/Users/admin
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
  tar -C "$s" -czf "$d/openclaw-backup.tar.gz" .openclaw
  rm -rf "$s"
  mkdir -p "$s/.openclaw" "$s/brain/harvester" "$s/brain/prompts" "$s/.wacli" "$s/.ssh" "$s/ops/bench"
  printf 'OP_SERVICE_ACCOUNT_TOKEN=old_home_value\n' > "$s/.openclaw/.env"
  echo '{}' > "$s/brain/harvester/package-lock.json"
  printf '{"wacliBin":"/usr/local/bin/wacli","storeDb":"%s/.wacli/wacli.db"}\n' "$O" > "$s/brain/harvester/config.json"
  if [ "${2:-}" = leftover ]; then printf 'Read %s/brain/queue first.\n' "$O" > "$s/brain/prompts/p.md"
  else echo 'Read ~/brain/queue first.' > "$s/brain/prompts/p.md"; fi
  printf '{"out":"%s/backups"}\n' "$O" > "$s/ops/bench/cfg.json"
  echo x > "$s/.wacli/session.db"
  echo 'ssh-ed25519 AAAAadminlogin admin-login' > "$s/.ssh/authorized_keys"
  echo deploy-key > "$s/.ssh/ocsb_vault"
  printf 'Host github-vault\n  IdentityFile %s/.ssh/ocsb_vault\n' "$O" > "$s/.ssh/config"
  echo 'github.com ssh-ed25519 AAAAhostkey' > "$s/.ssh/known_hosts"
  tar -C "$s" -czf "$d/filestate.tar.gz" .openclaw/.env brain .wacli .ssh ops
  rm -rf "$s"
  manifest "$d" nightly
}
jget() { node -e 'const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = process.argv[2].split(".").reduce((o, k) => (o == null ? o : o[k]), c); process.stdout.write(typeof v === "string" ? v : JSON.stringify(v))' "$@"; }
mkold "$t/old"; mkold "$t/oldleft" leftover

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
unset FAKE_TS_STATE FAKE_TS_OPERATOR

fresh
expect 0 "a drill completes" run_import drill "$t/full"
check "a drill's closing hint names the rehearsal acceptance (acceptance has no drill mode)" \
  grep -qxF 'import: done (drill). Now run tests/acceptance.sh rehearsal <lan-ip>' "$t/out"
fresh
expect 0 "a final completes" run_import final "$t/full"
check "a final's closing hint names the final acceptance" grep -qxF 'import: done (final). Now run tests/acceptance.sh final <lan-ip>' "$t/out"
```

- [ ] **Step 3: Run them to verify they fail**

Run: `bash migrate/import.test.sh`
Expected: exit 1. Among the failures: `FAIL: a nightly made by /Users/admin imports as final into another home (exit 1, want 0)` showing `restore layout unexpected: … found 0`, `FAIL: an import run as root is refused …`, `FAIL: a drill's closing hint names the rehearsal acceptance …`.

- [ ] **Step 4: Implement the import changes**

After line 6 of `migrate/import.sh` (the end of the `drill` description), add:

```bash
# Run it as the account that will own the state: the bot account (docs/superpowers/specs/2026-10-02-bot-user-sebastian-design.md).
# An archive made under another home (the in-place move from /Users/admin) has that home rewritten to $HOME in
# structured configuration (migrate/homepaths.mjs); any trace of it left in live configuration fails the import
# (migrate/scan-refs.mjs --old-home); and its authorized_keys is not installed.
```

After line 54 (the `for c in openclaw node npm op systemctl` loop), add:

```bash
# Restored as root, the state would be root's and the bot's units could not use it.
[ "$(id -u)" != 0 ] || die "run as the account that will own the state (the bot account), not as root"
# systemctl --user (the units, gateway install) needs this account's own user manager.
systemctl --user show-environment >/dev/null 2>&1 \
  || die "no systemd user manager for $(id -un): run through host/claw.sh sebastian -- … (it sets XDG_RUNTIME_DIR), and the account needs linger"
```

After line 58 (`. "$repo/ops/lib/dotenv-token.sh"`), add:

```bash
for f in migrate/homepaths.mjs migrate/scan-refs.mjs; do [ -f "$repo/$f" ] || die "$f missing from the repo checkout"; done
```

In the `serve|funnel)` branch (lines 106-109), after the `[ "$ts_state" = Running ] || die …` statement and before its `;;`, so that the branch reads:

```bash
    serve|funnel)
      ts_state=$(tailscale status --json 2>/dev/null | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0, "utf8")).BackendState ?? ""))' 2>/dev/null || true)
      [ "$ts_state" = Running ] \
        || die "gateway.tailscale.mode=$ts_mode needs a logged-in Tailscale (run: sudo tailscale up ...) before a final import (BackendState is '${ts_state:-unknown}')"
      # The gateway claims Serve itself; without root that takes the operator setting (provisioning sets it).
      ts_op=$(tailscale debug prefs 2>/dev/null | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0, "utf8")).OperatorUser ?? ""))' 2>/dev/null || true)
      [ "$ts_op" = "$(id -un)" ] \
        || die "gateway.tailscale.mode=$ts_mode: Tailscale's operator must be $(id -un), not '${ts_op:-none}' (host/claw.sh provision sets it once Tailscale is up)" ;;
```

Replace lines 130-136 (from `# Layout recorded in docs/verification.md` through `restored="${restored_dirs[0]}"`) with:

```bash
# Layout recorded in docs/verification.md: <target>/<archive root>/payload/posix<archive home>/.openclaw. The archive's
# home is the account that made it: this home on a rebuild, another one (/Users/admin) when the state moves to the
# bot account in place.
restored_dirs=()
while IFS= read -r d; do restored_dirs+=("$d"); done < <(find "$stage/r" -mindepth 4 -type d -name .openclaw -path "$stage/r/*/payload/posix/*" -prune -print)
[ "${#restored_dirs[@]}" -eq 1 ] \
  || die "restore layout unexpected: want exactly one $stage/r/<archive root>/payload/posix<home>/.openclaw, found ${#restored_dirs[@]} (see docs/verification.md)"
restored="${restored_dirs[0]}"
arch_home="${restored%/.openclaw}"
arch_home="/${arch_home#"$stage/r"/*/payload/posix/}"
if ! [[ $arch_home =~ ^(/[A-Za-z0-9._-]+)+$ ]] || [[ $arch_home == */../* || $arch_home == */.. ]]; then
  die "the archive's home '$arch_home' is not a plain absolute path"
fi
if [ "$arch_home" = "$H" ]; then rehome=0; else rehome=1; echo "import: the archive comes from $arch_home; its paths move to $H"; fi
# The bot account has no SSH login (spec 2026-10-02 §1): refuse before anything lands if this home already accepts one.
if [ "$rehome" = 1 ] && { [ -e "$H/.ssh/authorized_keys" ] || [ -e "$H/.ssh/authorized_keys2" ]; }; then
  die "$H/.ssh holds authorized_keys, but the account importing another home's state is the bot account, which must have no SSH login; remove the file (provisioning asserts it is absent)"
fi
```

Replace lines 164-171 (from `# File state.` through `if [ -n "$prev_keys" ]; then`) with:

```bash
# File state. The archive's wacli session and carried WhatsApp credential copies never reach the disk in
# rehearsal and drill. On the same home the guest already has authorized_keys entries of its own (Lima's): keep
# them. From another home (the bot account) the archive's login keys stay behind; only its deploy key, config
# and known_hosts land.
tar_excl=()
if [ "$no_wa" = 1 ]; then tar_excl=(--exclude '.wacli/session.db*' --exclude '.openclaw*/credentials/whatsapp*'); fi
if [ "$rehome" = 1 ]; then tar_excl+=(--exclude '.ssh/authorized_keys*'); fi
ak="$H/.ssh/authorized_keys"
prev_keys=$(cat "$ak" 2>/dev/null || true)
tar -C "$H" ${tar_excl[@]+"${tar_excl[@]}"} -xzf "$src/filestate.tar.gz"
if [ "$rehome" = 0 ] && [ -n "$prev_keys" ]; then
```

After line 185 (the `fi` closing the `if [ "$no_wa" = 1 ]` residue check), add:

```bash

# The archive's home in the live configuration becomes this home (spec 2026-10-02 §2 step 4) before anything runs on
# it. Whatever the rewrite cannot reach (free text, a file that is not JSON) fails the import here: before npm ci,
# the token or the gateway. Transcripts and databases keep their history.
home_scan() {
  local p
  local -a roots=("$H/.openclaw/openclaw.json" "$H/.openclaw/cron" "$H/.openclaw/skills" "$H/.openclaw/bin" "$H/.openclaw/bin/op-nosym"
                  "$H/.ssh/config" "$H/brain" "$H/brain/vault/.git/config" "$H/ops")
  for p in "$H"/.openclaw/workspace*/skills "$H"/.openclaw/workspace*/*.md; do
    if [ -e "$p" ]; then roots+=("$p"); fi
  done
  SCAN_ALLOW="$repo/migrate/scan-allow.txt" node "$repo/migrate/scan-refs.mjs" --old-home "$arch_home" "${roots[@]}" \
    || die "the live configuration still names $arch_home (see above): make it home-relative at the source, or teach migrate/homepaths.mjs that file"
}
if [ "$rehome" = 1 ]; then
  node "$repo/migrate/homepaths.mjs" "$arch_home" "$H" || die "the home rewrite failed (see above)"
  home_scan
fi
```

Replace the last two lines (272-273, `openclaw secrets audit …` and the closing `echo`) with:

```bash
# doctor and the gateway have worked on the state since: still nothing in live configuration names the old home.
if [ "$rehome" = 1 ]; then home_scan; fi
openclaw secrets audit --allow-exec --check || die "secrets audit reported findings (see above)"
case "$mode" in final) acc=final ;; *) acc=rehearsal ;; esac   # acceptance.sh knows rehearsal|final; a drill is checked as a rehearsal
echo "import: done ($mode). Now run tests/acceptance.sh $acc <lan-ip>"
```

- [ ] **Step 5: Run the tests**

Run: `bash migrate/import.test.sh && PATH="/bin:$PATH" /bin/bash migrate/import.test.sh && make lint`
Expected: `import guard rails: 200 passed, 0 failed` both times, and no shellcheck output.

- [ ] **Step 6: Prove the new tests bite**

Temporarily change `if [ "$rehome" = 1 ]; then tar_excl+=(--exclude '.ssh/authorized_keys*'); fi` to `true`: "no authorized_keys for the bot account …" must FAIL. Temporarily delete the first `home_scan` call: "free text that still names the old home fails the import …" must FAIL (the end-of-run scan still catches it, but only after npm and the gateway: "… before npm ci, the token or the gateway" FAILs). Restore both.

- [ ] **Step 7: Commit**

```bash
git add migrate/import.sh migrate/import.test.sh
git commit -m "feat(migrate): import another home's archive into the bot account" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The host pull streams the bot's backups

**Files:**
- Modify: `host/pull-backups.sh` (whole file), `host/install.sh` (whole file), `host/local.vm-claw.pull-backups.plist:7` (one line after it)
- Modify: `ops/backup/backup.test.sh:85-111` (fake limactl), `:145` (`reset_fakes`), `:361` (`pull_env`), `:377` (`copy_of`), `:396`, `:407`, `:420`, `:426`, `:486`, `:506`, `:550-553` (delete), new tests after `:557`, `:602`, and one plist check after the 06:15 check in Part 3
- Modify: `host/install.test.sh:58-63` (`run`), new tests before the summary line
- Test: `ops/backup/backup.test.sh`, `host/install.test.sh`

**Interfaces:**
- Consumes: `provision/bot.sh` (`BOT_USER`, `BOT_HOME`) from Task 1.
- Produces:
  - `host/pull-backups.sh` honours `CLAW_INSTANCE` (default `claw`). Every guest command is `limactl shell --workdir / <inst> -- sudo -n -u sebastian -- <cmd…>`: the listing `bash -c 'ls -d "$1"/claw-nightly-*Z 2>/dev/null | sort' _ /home/sebastian/backups`, one `tar -C /home/sebastian/backups -cf - <night>` per missing night (unpacked on the host into a fresh `<dest>/<night>.partial/`), and the stamp `bash -c 'umask 077; date … > "$1/.host-pull-ok.tmp" && mv …' _ /home/sebastian/backups`. A pulled night is kept only if it holds exactly `MANIFEST`, `openclaw-backup.tar.gz`, `filestate.tar.gz`, all plain files, passing the existing hash gate; it lands at mode 700 with 600 files. Everything else (lock, failed-night handling, per-night restic snapshots, retention, staleness alarm, stamp only after full success) is unchanged.
  - `host/install.sh` honours `CLAW_INSTANCE` (validated before any change); the installed plist carries `EnvironmentVariables` `CLAW_INSTANCE=<inst>`.

- [ ] **Step 1: Update the fake guest and the assertions in `ops/backup/backup.test.sh`**

Replace the fake `limactl` (lines 85-111) with:

```bash
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
```

Replace line 145 with (the merge backend is gone with `limactl copy`):

```bash
reset_fakes() { unset FAKE_COPY_VANISH FAKE_NOW FAKE_TAR_RC FAKE_TAR_MSG FAKE_ARCHIVES FAKE_OPENCLAW_FAIL FAKE_DF_AVAIL_KB FAKE_DATE FAKE_COPY_FAIL FAKE_SNAPSHOTS_FAIL FAKE_LIMA_DOWN FAKE_STAMP_FAIL FAKE_RESTIC_FAIL || true; }
```

In `pull_env` (line 361), add `-u CLAW_INSTANCE` after `env`:

```bash
pull_env() { env -u CLAW_INSTANCE -u CLAW_BACKUP_DEST -u RESTIC_REPOSITORY -u RESTIC_PASSWORD -u RESTIC_PASSWORD_COMMAND \
```

Replace line 377 with:

```bash
copy_of() { echo "^limactl shell --workdir / claw -- sudo -n -u sebastian -- tar -C /home/sebastian/backups -cf - claw-nightly-$(stamp "$1")Z\$"; }
hevF() { grep -qF -- "$1" "$t/hev"; }   # a literal fragment of the call log
```

Replace line 396 with:

```bash
check "every night is streamed by the bot's tar from its backups dir" bash -c '[ "$(grep -c "^limactl shell --workdir / claw -- sudo -n -u sebastian -- tar -C /home/sebastian/backups -cf - " "$1")" = 3 ]' _ "$t/hev"
```

Replace line 407 with:

```bash
check "only the missing nights were copied" bash -c '! grep -q " -cf - claw-nightly-$2Z$" "$1" && grep -q " -cf - claw-nightly-$3Z$" "$1" && grep -q " -cf - claw-nightly-$4Z$" "$1"' _ "$t/hev" "$(stamp 1)" "$(stamp 2)" "$(stamp 3)"
```

In line 420 and line 506, change `"^(limactl copy|restic)"` to `"^(limactl shell .* -- tar |restic)"`. In lines 426 and 486, change `'! grep -q "^limactl copy" "$1"'` to `'! grep -q " -- tar -C " "$1"'`.

Delete lines 550-553 (the `# Lima's rsync backend merges …` comment and the `FAKE_COPY_MERGE` case): the stream always lands in a fresh `.partial`, which the stale-`.partial` case just above still proves.

After line 557 (the `restic did not run` check closing the `# --- partial copies ---` block), add:

```bash

# --- the guest side runs as the bot account (spec 2026-10-02 §3) ---
mkhost; mkgood 1; mkgood 2
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
mkhost; mkgood 1
expect 0 "a pull with CLAW_INSTANCE set" pull_env CLAW_INSTANCE=claw-next CLAW_BACKUP_DEST="$dest" RESTIC_REPOSITORY="$rrepo" bash "$pull"
check "  ... sent every guest command to that instance" bash -c 'grep -q "^limactl shell --workdir / claw-next -- " "$1" && ! grep -q "^limactl shell --workdir / claw -- " "$1"' _ "$t/hev"
mkhost; mkgood 1
expect_msg 1 "not an instance name" "a CLAW_INSTANCE that is not an instance name is refused" pull_env 'CLAW_INSTANCE=x;y' CLAW_BACKUP_DEST="$dest" RESTIC_REPOSITORY="$rrepo" bash "$pull"
check "  ... before any guest command" bash -c '! grep -q "^limactl" "$1"' _ "$t/hev"
```

Replace the order check at line 602 with:

```bash
check "  ... written through a temp file and renamed (atomic), after restic and the checks" hin_order '^restic forget ' '^limactl shell --workdir / claw -- sudo -n -u sebastian -- bash -c .*> "\$1/\.host-pull-ok\.tmp" && mv "\$1/\.host-pull-ok\.tmp" "\$1/\.host-pull-ok" _ /home/sebastian/backups$'
```

In Part 3, after the check `"the plist schedules 06:15"`, add:

```bash
check "the plist hands the pull its instance (@INSTANCE@, substituted by host/install.sh)" \
  grep -qF '<key>EnvironmentVariables</key><dict><key>CLAW_INSTANCE</key><string>@INSTANCE@</string></dict>' "$plist"
```

- [ ] **Step 2: Add the install tests in `host/install.test.sh`**

In `run()` (line 61), change `env HOME="$H"` to `env -u CLAW_INSTANCE HOME="$H"`. Before the line `echo "install.test.sh: $pass passed, $fail failed"`, add:

```bash
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
```

- [ ] **Step 3: Run them to verify they fail**

Run: `bash ops/backup/backup.test.sh; bash host/install.test.sh`
Expected: both exit 1. `backup.test.sh` fails nearly every pull case (`cannot list the backups in the guest`, because the fake now exits 98 on a call that is not made as the bot); `install.test.sh` fails cases 15-17.

- [ ] **Step 4: Rewrite `host/pull-backups.sh`**

```bash
#!/bin/bash
# Host: pull every complete guest backup not yet here (host -> guest direction only), keep 14, send every night
# restic has no snapshot of yet (one snapshot per night), and only then fail: if a night could not be pulled or did
# not pass the gate (each is dropped and named, the others carry on), or if the guest has stopped producing nightlies
# (the newest one is more than 30 h old, or dated more than 1 h in the future).
# The backups belong to the bot account, whose home is mode 700 (spec 2026-10-02 §3), so every guest command runs as
# the bot through `sudo -n -u <bot>`: the listing, one tar stream per night into a fresh .partial, and the stamp.
# Knobs for tests and odd setups: CLAW_INSTANCE (default claw), CLAW_BACKUP_DEST (default ~/Backups/vm-claw),
# RESTIC_REPOSITORY, RESTIC_PASSWORD, RESTIC_PASSWORD_COMMAND. Runs under launchd (host/local.vm-claw.pull-backups.plist).
set -euo pipefail
# Appended, not prepended: launchd's PATH has no Homebrew, and a PATH the caller set (the tests' fakes) must win.
export PATH="$PATH:/opt/homebrew/bin"
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=provision/bot.sh
. "$repo/provision/bot.sh"
inst="${CLAW_INSTANCE:-claw}"
dest="${CLAW_BACKUP_DEST:-$HOME/Backups/vm-claw}"
keep=14
max_age_h=30
max_future_h=1
die() { echo "pull-backups: $*" >&2; exit 1; }
[[ $inst =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "CLAW_INSTANCE '$inst' is not an instance name (a-z, 0-9, -)"
gb="$BOT_HOME/backups"
as_bot=(limactl shell --workdir / "$inst" -- sudo -n -u "$BOT_USER" --)

# The same gate as migrate/import.sh: both archives listed with a 64-hex hash (the checker only skips a line
# it cannot parse, with a warning, unless --strict), then every hash checked. Only failures are printed
# (--quiet drops the OK lines), so the log says which file did not match. Before that: exactly the three files a
# nightly writes, each a plain file. The stream comes from the bot's side of the guest, so nothing else it carried
# (another file, a symlink) is kept.
# shellcheck disable=SC2012  # three fixed, plain names
verify() { # verify <dir>
  local f
  [ "$(cd "$1" 2>/dev/null && ls -A | LC_ALL=C sort | tr '\n' ' ')" = "MANIFEST filestate.tar.gz openclaw-backup.tar.gz " ] || return 1
  for f in MANIFEST openclaw-backup.tar.gz filestate.tar.gz; do
    if [ -L "$1/$f" ] || [ ! -f "$1/$f" ]; then return 1; fi
  done
  for f in openclaw-backup.tar.gz filestate.tar.gz; do
    awk -v f="$f" '$2 == f && $1 ~ /^[0-9a-f]{64}$/ { found = 1 } END { exit !found }' "$1/MANIFEST" || return 1
  done
  (cd "$1" && grep -v '^mode=' MANIFEST | shasum -a 256 --strict --quiet -c -)
}

# Complete backups only, oldest first: a *.partial is a run in flight (or killed) and is never pulled or
# counted. Every name is checked before anything is pulled.
# shellcheck disable=SC2016  # $1 is expanded by the guest's bash
list=$("${as_bot[@]}" bash -c 'ls -d "$1"/claw-nightly-*Z 2>/dev/null | sort' _ "$gb") \
  || die "cannot list the backups in the guest (is the $inst instance running, with the $BOT_USER account?)"
name_re='^claw-nightly-[0-9]{8}T[0-9]{6}Z$'
names=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  n=$(basename "$p")
  [[ $n =~ $name_re ]] || die "unexpected backup name '$n' from the guest"
  names+=("$n")
done <<<"$list"
[ "${#names[@]}" -gt 0 ] || die "no complete nightly backup in the guest"

mkdir -p "$dest"; chmod 700 "$dest"
# One run at a time: a mkdir lock (macOS has no flock). Everything below, the .partial sweeps included, runs
# while holding it.
lock="$dest/.lock"
have_lock=0; part=""
cleanup() {
  if [ -n "$part" ]; then rm -rf "$part"; fi
  if [ "$have_lock" = 1 ]; then rm -rf "$lock"; fi
  return 0
}
trap cleanup EXIT
if ! mkdir "$lock" 2>/dev/null; then
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
    # The run that held it is gone (killed, or the Mac restarted): take the lock over rather than let one
    # crash stop every later pull.
    mv "$lock" "$lock.stale.$$" 2>/dev/null && rm -rf "$lock.stale.$$"
    mkdir "$lock" 2>/dev/null || die "another pull took $lock just now"
  else
    die "another pull holds $lock${holder:+ (pid $holder)}; if none is running, remove it"
  fi
fi
have_lock=1
echo "$$" > "$lock/pid"

# One bad night must not cost the good ones after it (or restic): a night whose stream fails (the guest may have
# pruned it meanwhile) or whose gate fails is removed, named, and skipped; the run fails at the end.
failed=()
i=0
while [ "$i" -lt "${#names[@]}" ]; do
  name="${names[$i]}"
  if [ ! -d "$dest/$name" ]; then
    part="$dest/$name.partial"
    # A fresh, empty .partial every time: whatever a killed run left there must not mix into this copy.
    rm -rf "$part"; mkdir -m 700 "$part"
    why=""
    # The guest's tar runs as the bot (only it can read its home); the host unpacks into the .partial and nowhere else.
    if ! "${as_bot[@]}" tar -C "$gb" -cf - "$name" | tar -xf - -C "$part"; then
      why="the copy from the guest failed (pruned meanwhile?)"
    elif ! verify "$part/$name"; then
      why="it failed verification (MANIFEST, checksums, or files a nightly does not write)"
    fi
    if [ -n "$why" ]; then
      rm -rf "$part"; part=""
      echo "pull-backups: $name: $why; not keeping it" >&2
      failed+=("$name")
    else
      chmod 700 "$part/$name"; chmod 600 "$part/$name"/*
      mv "$part/$name" "$dest/$name"
      rm -rf "$part"; part=""
    fi
  fi
  i=$((i + 1))
done

# Keep the newest $keep complete backups (by name: the UTC timestamp), then sweep leftover .partial dirs
# so restic never snapshots them.
done_dirs=()
for d in "$dest"/claw-nightly-*Z; do
  if [ -d "$d" ]; then done_dirs+=("$d"); fi
done
i=0
while [ "$i" -lt $((${#done_dirs[@]} - keep)) ]; do
  rm -rf "${done_dirs[$i]}"
  i=$((i + 1))
done
rm -rf "$dest"/claw-nightly-*.partial

# Restic is reached whenever a complete night exists in $dest, even when some night failed; with none there is
# nothing to send. Snapshots are per night (below), forget runs every time.
if [ "${#done_dirs[@]}" -gt 0 ]; then
  if [ -z "${RESTIC_REPOSITORY:-}" ]; then
    icloud="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
    [ -d "$icloud" ] || die "iCloud Drive is off ($icloud is missing); not creating a local restic repository in its place"
    RESTIC_REPOSITORY="$icloud/Backups/vm-claw-restic"
  fi
  export RESTIC_REPOSITORY
  if [ -z "${RESTIC_PASSWORD:-}" ] && [ -z "${RESTIC_PASSWORD_COMMAND:-}" ]; then
    export RESTIC_PASSWORD_COMMAND="security find-generic-password -s vm-claw-restic -w"
  fi
  # `restic init` only for a repository that is not there. A failing `restic snapshots` (an evicted iCloud
  # file, a locked keychain) must fail the run, never start a second repository next to the real one.
  if [ ! -e "$RESTIC_REPOSITORY/config" ]; then
    if [ -d "$RESTIC_REPOSITORY" ] && [ -n "$(ls -A "$RESTIC_REPOSITORY")" ]; then
      die "restic repository $RESTIC_REPOSITORY has content but no config file; not initialising over it (an evicted iCloud file?)"
    fi
    restic init
  fi
  # One snapshot per night, never the whole folder: the nights are gzip'd tarballs that restic can neither
  # deduplicate across nights nor compress, so re-snapshotting the rolling 14-night folder would store each
  # night up to 14 times. Every complete night in $dest that restic holds no snapshot of is backed up, oldest
  # first (the glob above is sorted by name): a night whose backup failed or was cut off in an earlier run is
  # retried here, not lost. A failed night was dropped above and is never snapshotted. Which nights have one:
  # a single listing, matched on each snapshot's first path. The old folder-level snapshot (path $dest)
  # matches no night. A failing listing fails the run (set -e): it is never read as "nothing to back up".
  snaps=$(restic snapshots --json --tag vm-claw)
  have=$(printf '%s' "$snaps" | grep -o '"paths":\["[^"]*"' | sed 's/^"paths":\["//; s/"$//' || true)
  for d in "${done_dirs[@]}"; do
    [ -d "$d" ] || continue   # done_dirs was listed before the keep sweep removed the oldest
    if ! printf '%s\n' "$have" | grep -Fxq -- "$d"; then restic backup --tag vm-claw "$d"; fi
  done
  # --group-by host: restic groups snapshots by host+paths by default, and every night has its own path, so
  # each night would be a group of its own and nothing would ever expire. Grouped by host alone, the nights
  # (and the single folder-path snapshot older versions of this script took, same host, same tag) form one
  # group, and the keep policy counts snapshots, that is nights: about 34 retained nights.
  restic forget --tag vm-claw --group-by host --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
else
  echo "pull-backups: no complete night in $dest; nothing to send to restic" >&2
fi

# Only after restic has what exists: is the guest still producing nightlies? A failing nightly pulls nothing
# new and would otherwise look like success every morning; a future-dated name would stay "newest" forever.
problem=0
newest="${names[${#names[@]}-1]}"
newest_ts=$(date -j -u -f %Y%m%dT%H%M%SZ "${newest#claw-nightly-}" +%s) || die "cannot read a time from the name $newest"
age=$(( $(date -u +%s) - newest_ts ))
if [ "$age" -gt $((max_age_h * 3600)) ]; then
  echo "pull-backups: the newest guest nightly, $newest, is $((age / 3600)) h old (limit $max_age_h h): the guest has stopped producing backups (check its nightly timer); any night already here was still sent to restic" >&2
  problem=1
fi
if [ "$age" -lt $((0 - max_future_h * 3600)) ]; then
  echo "pull-backups: the newest guest nightly, $newest, is dated $((-age / 60)) min in the future (limit $max_future_h h): check the guest's clock; any night already here was still sent to restic" >&2
  problem=1
fi
# Last line of the log: every night that was dropped.
if [ "${#failed[@]}" -gt 0 ]; then
  echo "pull-backups: FAILED nights (dropped, not kept in $dest): ${failed[*]}" >&2
  problem=1
fi
[ "$problem" = 0 ] || exit 1

# Every night pulled and verified, restic backup and forget done, the guest still producing nightlies: tell the
# guest, whose daily check (ops/backup/backup-health.mjs) alarms when this stamp goes stale. Only on this path,
# never on a failing one; written as the bot, through a temp file renamed into place, so the check never reads
# half a line.
# shellcheck disable=SC2016  # $1 is expanded by the guest's bash
"${as_bot[@]}" bash -c 'umask 077; date -u +%Y-%m-%dT%H:%M:%SZ > "$1/.host-pull-ok.tmp" && mv "$1/.host-pull-ok.tmp" "$1/.host-pull-ok"' _ "$gb" \
  || die "could not write the host-pull stamp into the guest ($gb/.host-pull-ok); its backup-health check will alarm"
```

- [ ] **Step 5: Rewrite `host/install.sh` and add the plist line**

```bash
#!/bin/bash
# Host setup: Lima + restic, the backup pull agent. Safe to re-run. CLAW_INSTANCE (default claw) names the instance
# the agent pulls from (a rebuild may live under another name).
# Run over `ssh -t`: storing the restic password prompts on the terminal.
set -euo pipefail
# Over a non-login ssh the PATH lacks Homebrew; add it only when brew is not already reachable.
command -v brew >/dev/null || export PATH="$PATH:/opt/homebrew/bin"
repo="$(cd "$(dirname "$0")/.." && pwd)"
label=local.vm-claw.pull-backups
icloud="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
inst="${CLAW_INSTANCE:-claw}"
# Checked before anything else, like the iCloud check, so a bad value changes nothing.
if ! [[ $inst =~ ^[a-z0-9][a-z0-9-]*$ ]]; then echo "CLAW_INSTANCE '$inst' is not an instance name (a-z, 0-9, -)" >&2; exit 2; fi

# Checked first so a Mac without iCloud Drive changes nothing.
[ -d "$icloud" ] || {
  echo "iCloud Drive is not enabled on this Mac: enable it, or change RESTIC_REPOSITORY in host/pull-backups.sh" >&2; exit 1; }
echo "Reminder: in Finder set ~/Library/Mobile Documents/com~apple~CloudDocs/Backups/vm-claw-restic to \"Keep Downloaded\" so Optimize Storage cannot evict pack files."

command -v limactl >/dev/null || brew install lima
command -v restic >/dev/null || brew install restic
limactl --version
restic version

unlock_remedy() {
  echo "If the login keychain is locked (common over ssh), run:" >&2
  echo "  security unlock-keychain ~/Library/Keychains/login.keychain-db" >&2
  echo "then re-run host/install.sh." >&2
}
if ! security find-generic-password -s vm-claw-restic >/dev/null 2>&1; then
  echo "Store the restic password (also saved in 1Password) in the login keychain:"
  security add-generic-password -s vm-claw-restic -a "$USER" -w || {
    echo "Could not store the password." >&2
    unlock_remedy; exit 1; }
fi
security find-generic-password -s vm-claw-restic -w >/dev/null || {
  echo "Could not read the restic password back from the login keychain." >&2
  unlock_remedy; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
plist="$HOME/Library/LaunchAgents/$label.plist"
# Values are XML-escaped (the plist is XML), then sed-escaped (\, & and the # delimiter). The instance name needs
# neither: it is [a-z0-9-] only.
subst() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/[\\&#]/\\&/g'; }
tmp="$(mktemp "$plist.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
sed -e "s#@REPO@#$(subst "$repo")#g" -e "s#@HOME@#$(subst "$HOME")#g" -e "s#@INSTANCE@#$inst#g" "$repo/host/$label.plist" > "$tmp"
mv "$tmp" "$plist"

# Loaded only while the instance runs: a loaded agent against a stopped VM would fail every morning.
# Autostart is registered separately at cutover.
lerr="$(mktemp)"
status="$(limactl list "$inst" --format '{{.Status}}' 2>"$lerr")" || {
  echo "note: 'limactl list $inst' failed (treating $inst as not running): $(head -c 300 "$lerr")" >&2
  status=""; }
rm -f "$lerr"
if [ "$status" = "Running" ]; then
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  echo "pull agent loaded"
else
  echo "pull agent installed; it is loaded when $inst runs (re-run host/install.sh at cutover)"
fi
```

In `host/local.vm-claw.pull-backups.plist`, after line 7 (the `ProgramArguments` array), add:

```xml
  <key>EnvironmentVariables</key><dict><key>CLAW_INSTANCE</key><string>@INSTANCE@</string></dict>
```

- [ ] **Step 6: Run the tests**

Run: `bash ops/backup/backup.test.sh && bash host/install.test.sh && PATH="/bin:$PATH" /bin/bash ops/backup/backup.test.sh && PATH="/bin:$PATH" /bin/bash host/install.test.sh && make lint`
Expected: `backup scripts: 287 passed, 0 failed` and `install.test.sh: 17 passed, 0 failed`, each twice; no shellcheck output.

- [ ] **Step 7: Prove the stricter gate bites**

Temporarily delete the `if [ -L "$1/$f" ] || [ ! -f "$1/$f" ]` loop from `verify`: "a night whose archive arrives as a symlink is not kept …" must FAIL. Restore it.

- [ ] **Step 8: Commit**

```bash
git add host/pull-backups.sh host/install.sh host/local.vm-claw.pull-backups.plist host/install.test.sh ops/backup/backup.test.sh
git commit -m "feat(backup): host pull streams the bot's nights through sudo -u; CLAW_INSTANCE for the pull agent" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Listener guard: `--now` never restarts (#41), and a committed stranded-listener fixture

**Files:**
- Create: `ops/listener-guard/fixtures/stranded-listener/openclaw-2026-09-30.log`
- Modify: `ops/listener-guard/guard.mjs:59` (after `const dry = …`), `ops/listener-guard/guard.cli.test.mjs` (whole file), `ops/listener-guard/guard.test.mjs:3` (imports) and one appended test
- Test: `ops/listener-guard/guard.cli.test.mjs`, `ops/listener-guard/guard.test.mjs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces (Task 7 replays these on the guest):
  - `node guard.mjs --now <iso>` without `--dry-run` prints `guard: --now replays recorded history; it only runs with --dry-run (refusing to restart the gateway)` on stderr and exits 2, before reading any log or state.
  - The fixture dir `ops/listener-guard/fixtures/stranded-listener/`; replayed with `GUARD_LOG_DIR=<fixture> GUARD_STATE=<scratch> node guard.mjs --dry-run --now 2026-09-30T09:02:00Z` it prints exactly `[dry-run] 2026-09-30T09:02:00.000Z restart: stranded listener (2 events)` when `openclaw channels status` reports WhatsApp linked, and `[dry-run] 2026-09-30T09:02:00.000Z skip: WhatsApp not linked (2 events)` when it does not.

- [ ] **Step 1: Write the fixture**

`ops/listener-guard/fixtures/stranded-listener/openclaw-2026-09-30.log` (gateway log lines in OpenClaw's JSON shape: the gateway comes up, the listener starts, early noise inside the ready grace, unrelated lines, a non-JSON line, the two stranded-listener signatures, a signature with an unreadable date, and one after the replay time):

```
{"0":"{\"subsystem\":\"gateway\"}","1":"gateway ready","_meta":{"date":"2026-09-30T08:00:00.000Z","logLevelName":"INFO"}}
{"0":"{\"subsystem\":\"gateway/channels/whatsapp\"}","1":"Listening for WhatsApp inbound messages (DM + all groups)","_meta":{"date":"2026-09-30T08:00:05.000Z","logLevelName":"INFO"}}
{"0":"{\"subsystem\":\"gateway/channels/whatsapp\"}","1":"No active WhatsApp Web listener (account: default)","_meta":{"date":"2026-09-30T08:01:00.000Z","logLevelName":"WARN"}}
{"0":"{\"subsystem\":\"cron\"}","1":"job finished","_meta":{"date":"2026-09-30T08:30:00.000Z","logLevelName":"INFO"}}
gateway: a plain-text line that is not JSON and is skipped
{"0":"{\"subsystem\":\"gateway\"}","1":"Gateway client authority closed before dispatching cron.list","_meta":{"date":"2026-09-30T09:00:30.000Z","logLevelName":"WARN"}}
{"0":"{\"subsystem\":\"gateway/channels/whatsapp\"}","1":"The reply channel changed or cannot preserve its sender; delivery was not started.","_meta":{"date":"2026-09-30T09:00:32.000Z","logLevelName":"WARN"}}
{"1":"No active WhatsApp Web listener (account: default)","_meta":{"date":"not a date"}}
{"0":"{\"subsystem\":\"gateway/channels/whatsapp\"}","1":"No active WhatsApp Web listener (account: default)","_meta":{"date":"2026-09-30T09:03:00.000Z","logLevelName":"WARN"}}
```

- [ ] **Step 2: Write the failing tests**

Replace `ops/listener-guard/guard.cli.test.mjs` with (live runs are now dated relative to the real clock, because `--now` can no longer restart):

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const guardPath = path.join(path.dirname(fileURLToPath(import.meta.url)), "guard.mjs");
// The committed stranded-listener log (tests/acceptance.sh replays it on the guest) and the moment it is replayed at.
const FIXTURE = path.join(path.dirname(guardPath), "fixtures", "stranded-listener");
const REPLAY_AT = "2026-09-30T09:02:00Z";
// Live runs (no --now) are judged against the real clock, so their logs are dated relative to it.
const MIN = 60e3;
const NOW = Date.now();
const ago = (ms) => new Date(NOW - ms).toISOString();

const line = (iso, msg) => JSON.stringify({ 1: msg, _meta: { date: iso } });
const BASE = [line(ago(62 * MIN), "gateway ready"), line(ago(61 * MIN), "Listening for WhatsApp inbound messages (DM + all groups)")];
const STRANDED = [
  line(ago(90e3), "Gateway client authority closed before dispatching cron.list"),
  line(ago(88e3), "The reply channel changed or cannot preserve its sender; delivery was not started."),
];
const LINKED = 'echo "- WhatsApp default: enabled, configured, linked, running, connected"';
const NOT_LINKED = 'echo "- WhatsApp default: enabled, configured, not linked, stopped"';

// An isolated sandbox: a log dir (synthetic, or the committed fixture), a stub `openclaw` that records each call, a
// state file path, and a restart command that only touches a marker.
function sandbox({ logs = [...BASE, ...STRANDED], logDir: fixedLogDir, stub = LINKED, state, withStub = true }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "guard-cli-"));
  const binDir = path.join(dir, "bin");
  fs.mkdirSync(binDir);
  const logDir = fixedLogDir ?? path.join(dir, "logs");
  if (!fixedLogDir) {
    fs.mkdirSync(logDir);
    fs.writeFileSync(path.join(logDir, "openclaw-2026-09-30.log"), logs.join("\n") + "\n");
  }
  if (withStub) fs.writeFileSync(path.join(binDir, "openclaw"), `#!/bin/sh\necho "$@" >> "$STUB_CALLS"\n${stub}\n`, { mode: 0o755 });
  const p = { dir, calls: path.join(dir, "calls.txt"), marker: path.join(dir, "restarted"), stateFile: path.join(dir, "state", "g.json") };
  if (state) {
    fs.mkdirSync(path.dirname(p.stateFile), { recursive: true });
    fs.writeFileSync(p.stateFile, JSON.stringify(state));
  }
  p.run = (extraArgs = []) => spawnSync(process.execPath, [guardPath, ...extraArgs], {
    encoding: "utf8",
    env: {
      // Stub dir only when the stub is wanted; otherwise an empty dir so the real `openclaw` can never be found.
      PATH: withStub ? `${binDir}${path.delimiter}${process.env.PATH}` : binDir,
      GUARD_LOG_DIR: logDir,
      GUARD_STATE: p.stateFile,
      GUARD_RESTART: `touch "${p.marker}"`,
      STUB_CALLS: p.calls,
    },
  });
  p.calledTimes = () => (fs.existsSync(p.calls) ? fs.readFileSync(p.calls, "utf8").trim().split("\n").length : 0);
  p.cleanup = () => fs.rmSync(dir, { recursive: true, force: true });
  return p;
}

test("failing `channels status` yields a skip, never a blind restart, and exits 0", (t) => {
  const s = sandbox({ stub: "exit 1" });
  t.after(s.cleanup);
  const r = s.run();
  assert.equal(r.status, 0);
  assert.match(r.stdout, /skip: WhatsApp status unknown/);
  assert.match(r.stderr, /status check failed: exit 1/);
  assert.equal(s.calledTimes(), 1);
  assert.equal(fs.existsSync(s.marker), false, "gateway must not be restarted");
  assert.equal(fs.existsSync(s.stateFile), false, "no restart recorded");
});

test("`openclaw` missing from PATH yields a skip and exits 0", (t) => {
  const s = sandbox({ withStub: false });
  t.after(s.cleanup);
  const r = s.run();
  assert.equal(r.status, 0);
  assert.match(r.stdout, /skip: WhatsApp status unknown/);
  assert.match(r.stderr, /status check failed: ENOENT/);
  assert.equal(fs.existsSync(s.marker), false);
});

test("a linked WhatsApp plus a stranded log restarts the gateway and records it (control)", (t) => {
  const s = sandbox({});
  t.after(s.cleanup);
  const r = s.run();
  assert.equal(r.status, 0);
  assert.match(r.stdout, /restart: stranded listener \(2 events\)/);
  assert.equal(s.calledTimes(), 1);
  assert.equal(fs.existsSync(s.marker), true);
  const { restarts } = JSON.parse(fs.readFileSync(s.stateFile, "utf8"));
  assert.equal(restarts.length, 1);
  assert.ok(restarts[0] >= NOW && restarts[0] <= Date.now(), "the restart is recorded at the time it happened");
});

test("during cooldown the gateway status is not queried at all", (t) => {
  const s = sandbox({ state: { restarts: [NOW - 17 * MIN] } });
  t.after(s.cleanup);
  const r = s.run();
  assert.equal(r.status, 0);
  assert.match(r.stdout, /skip: cooldown/);
  assert.equal(s.calledTimes(), 0, "status must not be called when it cannot change the outcome");
  assert.equal(fs.existsSync(s.marker), false);
});

test("at the daily cap the gateway status is not queried either", (t) => {
  const s = sandbox({ state: { restarts: [6, 5, 4, 3, 2, 1].map((h) => NOW - h * 3600e3) } });
  t.after(s.cleanup);
  const r = s.run();
  assert.equal(r.status, 0);
  assert.match(r.stdout, /skip: 6 restarts in 24h/);
  assert.equal(s.calledTimes(), 0);
});

test("a quiet log is silent and does not query the gateway status", (t) => {
  const s = sandbox({ logs: BASE });
  t.after(s.cleanup);
  const r = s.run();
  assert.equal(r.status, 0);
  assert.equal(r.stdout, "");
  assert.equal(s.calledTimes(), 0);
});

test("--now without --dry-run refuses: exit 2, says why, never restarts, records nothing, asks nothing (#41)", (t) => {
  const s = sandbox({ logDir: FIXTURE });
  t.after(s.cleanup);
  const r = s.run(["--now", REPLAY_AT]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /--now replays recorded history; it only runs with --dry-run \(refusing to restart the gateway\)/);
  assert.equal(r.stdout, "");
  assert.equal(fs.existsSync(s.marker), false, "a replay must never restart the gateway");
  assert.equal(fs.existsSync(s.stateFile), false);
  assert.equal(s.calledTimes(), 0);
});

test("the committed stranded-listener fixture replays to a restart decision, and only a dry one", (t) => {
  const s = sandbox({ logDir: FIXTURE });
  t.after(s.cleanup);
  const r = s.run(["--dry-run", "--now", REPLAY_AT]);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout, "[dry-run] 2026-09-30T09:02:00.000Z restart: stranded listener (2 events)\n");
  assert.equal(fs.existsSync(s.marker), false);
  assert.equal(fs.existsSync(s.stateFile), false);
  assert.equal(s.calledTimes(), 1, "the linked check is asked once");
});

test("the fixture with WhatsApp not linked replays to a skip (what a rehearsal guest shows)", (t) => {
  const s = sandbox({ logDir: FIXTURE, stub: NOT_LINKED });
  t.after(s.cleanup);
  const r = s.run(["--dry-run", "--now", REPLAY_AT]);
  assert.equal(r.status, 0);
  assert.equal(r.stdout, "[dry-run] 2026-09-30T09:02:00.000Z skip: WhatsApp not linked (2 events)\n");
});

test("the fixture replayed before its stranded events finds none", (t) => {
  const s = sandbox({ logDir: FIXTURE });
  t.after(s.cleanup);
  const r = s.run(["--dry-run", "--now", "2026-09-30T09:00:00Z"]);
  assert.equal(r.status, 0);
  assert.equal(r.stdout, "ok: 0 event(s) in window\n");
  assert.equal(s.calledTimes(), 0);
});
```

In `ops/listener-guard/guard.test.mjs`, after line 3 (`import { decide } from "./guard.mjs";`), add:

```js
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
```

and append:

```js
test("the committed stranded-listener fixture decides restart at its replay time, on its two stranded events", () => {
  const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures", "stranded-listener");
  const lines = fs.readdirSync(dir).flatMap((f) => fs.readFileSync(path.join(dir, f), "utf8").split("\n"));
  assert.deepEqual(decide({ lines, now: Date.parse("2026-09-30T09:02:00Z"), linked: true, restarts: [] }),
    { action: "restart", reason: "stranded listener", events: 2 });
});
```

- [ ] **Step 3: Run them to verify they fail**

Run: `node --test ops/listener-guard/guard.test.mjs ops/listener-guard/guard.cli.test.mjs`
Expected: FAIL in `--now without --dry-run refuses …` (status 0 with a real `restart:` line and the marker created, instead of 2). The fixture tests pass already (the decision logic is unchanged); the refusal is the change.

- [ ] **Step 4: Implement the refusal**

In `ops/listener-guard/guard.mjs`, after line 59 (`const dry = args.includes("--dry-run");`), add:

```js
  // --now replays recorded history. It never acts on it: a replay with --dry-run forgotten must not restart a live
  // gateway (final review, minor #41).
  if (args.includes("--now") && !dry) {
    console.error("guard: --now replays recorded history; it only runs with --dry-run (refusing to restart the gateway)");
    process.exit(2);
  }
```

- [ ] **Step 5: Run the tests**

Run: `node --test ops/listener-guard/guard.test.mjs ops/listener-guard/guard.cli.test.mjs && make unit`
Expected: `ℹ tests 35`, `ℹ fail 0` for the guard tests, and `make unit` passes.

- [ ] **Step 6: Commit**

```bash
git add ops/listener-guard/guard.mjs ops/listener-guard/guard.cli.test.mjs ops/listener-guard/guard.test.mjs ops/listener-guard/fixtures/stranded-listener/openclaw-2026-09-30.log
git commit -m "fix(guard): --now only with --dry-run; commit a stranded-listener replay fixture" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Acceptance runs as the bot (I-1, #41 on the guest, #54)

**Files:**
- Modify: `tests/acceptance.sh` (whole file), `tests/acceptance.test.sh` (fakes `:60-121`, staging `:122-128`, `fresh` `:131-140`, item names and helpers `:180-216`, literal counts `:221-246`, `:278-280`, `:290`, `:315`, `:352-353`, LAN loops `:486-494`, and a new Part 9 before `# ===== Part 8`)
- Test: `tests/acceptance.test.sh`

**Interfaces:**
- Consumes: the guard refusal and fixture (Task 6): `ops/listener-guard/fixtures/stranded-listener`, replay time `2026-09-30T09:02:00Z`, expected lines `[dry-run] 2026-09-30T09:02:00.000Z restart: stranded listener (2 events)` / `… skip: WhatsApp not linked (2 events)`, refusal text `only runs with --dry-run`.
- Produces (Task 8 runs it through `"${BOT_SESSION[@]}" bash /opt/vm-claw/tests/acceptance.sh <mode> <lan-ip>`):
  - Usage unchanged: `acceptance.sh rehearsal|final <lan-ip>`; a LAN address whose first octet is `0` or `127` exits 2 with `… is not a LAN address …`.
  - Items, in order: `privilege: the bot account cannot become root or touch the firewall`, `privilege: every bot process runs as the bot account`, `secrets audit: 0 unresolved`, `update status: no failed run, installed version is at least the pin`, `agent probe: primary`, `agent probe: fallback`, `firewall`, `listener guard dry run`, `listener guard replays a stranded-listener log and would restart`, `listener guard refuses --now without --dry-run`, `gateway log dir belongs to the bot account (the guard reads it)`, `memory index paths are under this home`, `vault remote reachable with deploy key`; `final` adds `WhatsApp linked + connected`, `wacli authenticated`, `harvest health ok`.
  - MANUAL lines: both modes print the doctor and memory-search lines; `final` adds seven more (see the code).

- [ ] **Step 1: Write the failing tests** (Step 1 below edits `tests/acceptance.test.sh`; the script follows in Step 3)

Line numbers are those of the file before this step; apply the edits bottom-up or match the quoted text.

(a) Fakes. Replace the fake `node` (lines 100-105) with:

```bash
cat > "$t/bin/node" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "node $* | logdir=${GUARD_LOG_DIR:-} state=${GUARD_STATE:+set}"
case " $* " in
  *" --dry-run --now "*) hold replay; reply replay "[dry-run] 2026-09-30T09:02:00.000Z restart: stranded listener (2 events)" ;;
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
```

In the fake `openclaw`'s `case "$1 $2" in` block (after the `"channels status")` entry), add:

```bash
  "memory status")   reply memory "Memory (main)
  workspaceDir: $HOME/.openclaw/workspace
  dbPath: $HOME/.openclaw/memory/main.sqlite
  files: 42, chunks: 310" ;;
```

After the fake `timeout` (line 112), add:

```bash
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
reply nft ""
EOF
cat > "$t/bin/systemctl" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "systemctl $*"
if [ "$*" = "--user show openclaw-gateway.service -p MainPID --value" ]; then reply mainpid 4242; fi
reply systemctl ""
EOF
cat > "$t/bin/ps" <<'EOF'
#!/bin/bash
. "$FAKE_BIN/.fake.sh"
logcall "ps $*"
case "$*" in
  "-o uid= -p "*) reply psowner "  $(id -u)" ;;
  "-eo uid=,args=") reply pstable "$(cat "$FAKE_PSTABLE")" ;;
esac
reply ps ""
EOF
```

(b) Staging. After `cp "$repo/provision/vercmp.sh" "$t/repo/provision/"` (line 125), add:

```bash
mkdir -p "$t/repo/ops/listener-guard/fixtures/stranded-listener"
cp "$repo/ops/listener-guard/fixtures/stranded-listener/"*.log "$t/repo/ops/listener-guard/fixtures/stranded-listener/"
# The process table ps shows: the bot's gateway and guard under this uid, system processes, and another account's
# near misses (an old log of the gateway's is not the gateway). $other is never this uid.
other=4999; if [ "$(id -u)" = 4999 ]; then other=4998; fi
printf '    0 /sbin/init\n  %s /usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js gateway --port 18789\n  %s /usr/bin/node %s/ops/listener-guard/guard.mjs\n    0 /usr/sbin/sshd -D\n %s -bash\n %s less /tmp/openclaw.pre-rehome-20261002T120000Z/openclaw-2026-10-02.log\n' \
  "$(id -u)" "$(id -u)" "$t/home" "$other" "$other" > "$t/pstable"
export FAKE_PSTABLE="$t/pstable"
# A toolbox without nft (and without the system dirs), for the missing-nft test.
mkdir -p "$t/nonft"
for f in "$t/bin/"*; do if [ "$(basename "$f")" != nft ]; then ln -s "$f" "$t/nonft/$(basename "$f")"; fi; done
for c in bash dirname sed grep cat mktemp rm tail cut head tr sort awk env jq id wc basename; do p=$(command -v "$c") && ln -sf "$p" "$t/nonft/$c"; done
```

(c) `fresh()` (lines 131-140): in its `rm -rf` line add `"${t:?}/gwlog"`, in its `mkdir -p` line add `"$t/home/.config/systemd/user" "$t/gwlog"`, and before its closing `unset ACC_PATH ACC_EXTRA || true` add:

```bash
  printf '[Service]\nType=oneshot\nEnvironment=GUARD_LOG_DIR=%s\n' "$t/gwlog" > "$t/home/.config/systemd/user/openclaw-listener-guard.service"
  echo '{"1":"gateway ready"}' > "$t/gwlog/openclaw-2026-10-02.log"
  unset FAKE_REFUSE_RESTARTS || true
```

(d) Replace the item names and the helpers that count them (lines 180-216, from `I_AUDIT=` through the end of `item_with`) with:

```bash
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
```

(e) Part 1 (lines 221-246): change the description `"rehearsal prints PASS for exactly the seven items, in checklist order"` to `"rehearsal prints PASS for exactly the rehearsal items, in checklist order"`; replace the check `"rehearsal prints no FAIL and no MANUAL"` with:

```bash
check "rehearsal prints no FAIL" bash -c '! grep -Eq "^FAIL " "$1"' _ "$t/out"
check "rehearsal prints exactly the two MANUAL lines a drill can answer, verbatim and in order" test "$(sed -n 's/^MANUAL //p' "$t/out")" = "$MANUAL_REH"
```

change `"final prints PASS for the seven items plus the three final-only ones, in order"` to `"final prints PASS for the rehearsal items plus the three final-only ones, in order"`, and replace the `"final prints exactly the four MANUAL lines, verbatim and in order"` check (lines 241-246) with:

```bash
check "final prints exactly the nine MANUAL lines, verbatim and in order" test "$(sed -n 's/^MANUAL //p' "$t/out")" = "$MANUAL_FIN"
```

(f) Literal counts: in lines 278 and 280 change `only_fails "$I_HARVEST" 9` to `only_fails "$I_HARVEST" $((n_fin - 1))`; in line 290 change `-eq 4` to `-eq 9`; in line 315 change `only_fails "$I_UPDATE" 6` to `only_fails "$I_UPDATE" $((n_reh - 1))`; replace lines 352-353 with:

```bash
check "both probes failing: both are FAIL and every other item ran" \
  bash -c '[ "$(grep -c "^FAIL " "$1")" -eq 2 ] && [ "$(grep -c "^PASS " "$1")" -eq "$2" ]' _ "$t/out" $((n_reh - 2))
```

(g) LAN addresses: in the `for good in 192.0.2.10 0.0.0.0 255.255.255.255; do` line (492), replace `0.0.0.0` with `10.0.0.1`; and before that loop add:

```bash
# 0.x and 127.x are this machine, not the LAN: a "blocked" there proves nothing (final review, minor #54).
for bad in 0.0.0.0 127.0.0.1 0.1.2.3 127.255.255.254; do
  fresh; acc rehearsal "$bad"
  check "LAN argument '$bad': exit 2, named as not a LAN address" \
    bash -c '[ "$1" -eq 2 ] && grep -q "is not a LAN address" "$2" && grep -q "^usage: " "$2"' _ "$rc" "$t/err"
  check "LAN argument '$bad': nothing ran and nothing was called" bash -c '[ ! -s "$1" ] && ! grep -Eq "^(PASS|FAIL|MANUAL) " "$2"' _ "$FAKE_LOG" "$t/out"
done
```

(h) Before the line `# ===== Part 8: usage and dependencies ===…`, add:

```bash
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
if ! (PATH=/usr/sbin:/sbin; command -v nft) >/dev/null 2>&1; then
  fresh; ACC_PATH="$t/nonft"; acc rehearsal "$LAN"
  check "$I_ROOT: nft missing -> FAIL (it cannot be shown), the rest PASS" only_fails "$I_ROOT" $((n_reh - 1))
fi

# Every bot process is this account's: the gateway's main process, and nothing bot-like under another uid.
fresh; acc rehearsal "$LAN"
check "the owner check asks systemd for the gateway's main process, then ps" \
  log_order '^systemctl --user show openclaw-gateway.service -p MainPID --value \|' '^ps -o uid= -p 4242 \|' '^ps -eo uid=,args= \|'
fresh; export FAKE_OUT_mainpid=0; acc rehearsal "$LAN"
check "$I_OWNER: no gateway main process -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
fresh; export FAKE_OUT_psowner=" $other"; acc rehearsal "$LAN"
check "$I_OWNER: the gateway's main process run by another uid -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
for bad in "/usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js gateway --port 18789" "openclaw-gateway" \
           "/usr/local/bin/wacli sync --follow" "/bin/bash /home/other/ops/backup/nightly-backup.sh" \
           "/usr/bin/node /home/other/ops/listener-guard/guard.mjs" "/usr/bin/node /home/other/brain/harvester/harvest.mjs"; do
  fresh; FAKE_OUT_pstable="$(cat "$t/pstable")
 $other $bad"; export FAKE_OUT_pstable; acc rehearsal "$LAN"
  check "$I_OWNER: another account runs [$bad] -> FAIL" only_fails "$I_OWNER" $((n_reh - 1))
done

# The guard reads the gateway's log dir; after an in-place move it must be this account's (Review Focus 1).
fresh; rm -rf "$t/gwlog"; acc rehearsal "$LAN"
check "$I_GWLOG: the guard's log dir missing -> FAIL" only_fails "$I_GWLOG" $((n_reh - 1))
fresh; rm -f "$t/gwlog"/*; acc rehearsal "$LAN"
check "$I_GWLOG: no log file of this account -> FAIL" only_fails "$I_GWLOG" $((n_reh - 1))
fresh; printf '[Service]\nEnvironment=GUARD_LOG_DIR=/\n' > "$t/home/.config/systemd/user/openclaw-listener-guard.service"; acc rehearsal "$LAN"
check "$I_GWLOG: a log dir of another user -> FAIL" only_fails "$I_GWLOG" $((n_reh - 1))
check "  ... saying whose logs the guard would read" out_re 'belongs to another user'

# The memory index's paths.
fresh; acc rehearsal "$LAN"
check "memory status is asked for the main agent" log_re '^openclaw memory status --agent main \|'
item_with rehearsal "$I_MEMORY" memory "workspaceDir: /Users/admin/.openclaw/workspace
dbPath: $t/home/.openclaw/memory/main.sqlite" FAIL
check "  ... naming the stray path" out_re 'memory paths outside .*/Users/admin/\.openclaw/workspace'
item_with rehearsal "$I_MEMORY" memory "workspaceDir: ~/.openclaw/workspace
dbPath: ~/.openclaw/memory/main.sqlite" PASS
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bash tests/acceptance.test.sh`
Expected: exit 1, ending `acceptance script: N passed, M failed` with M > 0; among them `FAIL: rehearsal prints PASS for exactly the rehearsal items, in checklist order` and `FAIL: LAN argument '0.0.0.0': exit 2, named as not a LAN address`.

- [ ] **Step 3: Rewrite `tests/acceptance.sh`**

```bash
#!/bin/bash
# Guest-side acceptance checks (spec 2026-09-30 §3 checklist; spec 2026-10-02 §3). Run inside the guest AS THE BOT
# ACCOUNT, from the deployed repo, after migrate/import.sh:
#   host/claw.sh sebastian -- bash /opt/vm-claw/tests/acceptance.sh rehearsal|final <lan-ip>
#   rehearsal  the automated items that need neither WhatsApp nor cron, and the MANUAL lines a drill can answer
#   final      the same, plus the WhatsApp / wacli / harvester items, then every MANUAL line the owner confirms
# Prints PASS / FAIL / MANUAL per item; exits 1 if anything FAILed, 2 on bad usage.
#
# Every automated item has two halves, and both must hold: the command that produces the evidence exits 0,
# and what it printed matches. Output is captured into variables and matched there, never piped into
# `grep -q` (under pipefail that turns the producer's SIGPIPE into a false FAIL). stdout and stderr are kept
# apart, so a warning on stderr cannot spoil a JSON reply.
#
# Neither token ever reaches argv, a file or the screen. The 1Password bootstrap token is PARSED out of
# ~/.openclaw/.env (never sourced) by the parser shared with import.sh and the nightly backup; the gateway
# token is read from 1Password with it. Both live in shell variables and in the environment of the commands
# that need them, as in import.sh. On a FAIL the tail of a command's output is shown with both tokens masked.
# shellcheck disable=SC2329  # the check_* functions are run by `item`, not called by name
set +x   # before anything reads a token: `bash -x` or SHELLOPTS=xtrace must not trace the assignments
set -uo pipefail

usage() { echo "usage: $0 rehearsal|final <lan-ip>" >&2; exit 2; }
die() { echo "acceptance: $*" >&2; exit 1; }
mode="${1:-}"; lan="${2:-}"
case "$mode" in rehearsal|final) ;; *) usage ;; esac
if [ -z "$lan" ] || [ "$#" -ne 2 ]; then usage; fi
# firewall-check.sh interpolates the address into a `bash -c` string, so nothing but a dotted quad gets that far.
octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
lan_re="^$octet\\.$octet\\.$octet\\.$octet\$"
if ! [[ $lan =~ $lan_re ]]; then
  printf "acceptance: '%s' is not a dotted-quad IPv4 address\n" "$lan" >&2
  usage
fi
# 0.x (this host) and 127.x (loopback) reach the guest itself: a "blocked" there proves nothing about the LAN.
case "${lan%%.*}" in
  0|127) printf "acceptance: '%s' is not a LAN address (0.x and 127.x are this machine)\n" "$lan" >&2; usage ;;
esac
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=provision/vercmp.sh
. "$here/../provision/vercmp.sh"

# How the WhatsApp account reads in `openclaw channels status` while the Gateway is up: taken from
# OpenClaw's source (docs/verification.md) and from the shape the listener guard matches (its regex is this
# one without the last two words). The config-only fallback the CLI prints while the Gateway is down (it still
# exits 0) has no running or connected words, so it cannot match.
WA_LINKED_RE='^- WhatsApp default:.*, linked, running, connected'
# The listener-guard replay (final review I-1): the committed stranded-listener log, read by the guard that is
# installed and running, at a fixed moment. ops/listener-guard/guard.cli.test.mjs pins what it decides.
GUARD_FIXTURE="$here/../ops/listener-guard/fixtures/stranded-listener"
GUARD_REPLAY_AT=2026-09-30T09:02:00Z
# Command lines of the bot's own processes wherever ps shows them: the gateway and CLI (as a command or as a node
# module path), the guard, the nightly, the WhatsApp CLI and the harvester.
BOT_PROC_RE='(^|[/[:space:]])openclaw(-gateway)?([/[:space:]]|$)|listener-guard/guard\.mjs|backup/nightly-backup\.sh|(^|[/[:space:]])wacli([[:space:]]|$)|brain/harvester/'

command -v jq >/dev/null 2>&1 || die "jq not found (provision.sh installs it)"
# The probe sessions must not outlive the run, however it ends. They are deleted at the normal point below and
# from the EXIT trap, once, and only if a probe may have started (before that nothing is asked of openclaw, so
# a run that dies early calls nothing). A failed delete only warns: the sessions are clutter, not an acceptance
# failure, and what the delete prints is never shown.
probes_started=0; sessions_deleted=0
delete_probe_sessions() {
  if [ "$probes_started" -ne 1 ] || [ "$sessions_deleted" -eq 1 ]; then return 0; fi
  sessions_deleted=1
  if ! openclaw sessions delete agent:main:bench:acc-primary agent:main:bench:acc-fallback --agent main --yes >/dev/null 2>&1 </dev/null; then
    echo "acceptance: note: could not delete the probe sessions (they may not exist; if they do, remove them by hand: agent:main:bench:acc-primary agent:main:bench:acc-fallback)" >&2
  fi
}
# An explicit template: BSD mktemp with no argument ignores TMPDIR.
errf=$(mktemp "${TMPDIR:-/tmp}/acceptance.XXXXXX") || die "cannot create a temp file"
cleanup() { delete_probe_sessions; rm -f "$errf"; }
trap cleanup EXIT
# Ctrl-C and kill leave through the EXIT trap too, with the usual 128+signal status. A trap runs once the command
# in flight is done (Ctrl-C reaches that command as well; a TERM sent to this script alone waits for it).
trap 'echo "acceptance: interrupted" >&2; exit 130' INT
trap 'echo "acceptance: terminated" >&2; exit 143' TERM

# --- tokens: before any item runs -------------------------------------------------------------------
lib="$here/../ops/lib/dotenv-token.sh"
[ -f "$lib" ] || die "$lib is missing from the repo checkout"
# shellcheck source=ops/lib/dotenv-token.sh
. "$lib"
dotenv="$HOME/.openclaw/.env"
[ -f "$dotenv" ] || die "$dotenv is missing; run migrate/import.sh first"
op_token=$(dotenv_token "$dotenv") || die "the bootstrap token in $dotenv is unusable (see above)"
export OP_SERVICE_ACCOUNT_TOKEN="$op_token"
# op's own stderr is not shown: a rejected-token message could carry the token.
gw_token=$(op read "op://Sebastian/OpenClaw Gateway Token/password" 2>/dev/null </dev/null) \
  || die "cannot read the gateway token from 1Password (op missing, not signed in, or offline; its own message is hidden because it could carry a token)"
[ -n "$gw_token" ] || die "the gateway token read from 1Password is empty"
export OPENCLAW_GATEWAY_TOKEN="$gw_token"

# --- plumbing -----------------------------------------------------------------------------------------
fail=0
OUT=""; ERR=""; RC=0; WHY=""
# run CMD...: OUT = its stdout, ERR = its stderr, RC = its exit status. Stdin is closed: no command may
# wait on the terminal.
run() {
  OUT=$("$@" 2>"$errf" </dev/null); RC=$?
  ERR=$(cat "$errf")
}
# produce CMD...: run it; fails (with the status as the reason) unless it exits 0.
produce() {
  run "$@"
  [ "$RC" -eq 0 ] && return 0
  WHY="exit $RC"; return 1
}
# matches ERE REASON: OUT must match; REASON is what a FAIL says otherwise.
matches() {
  grep -Eq -- "$1" <<<"$OUT" && return 0
  WHY="$2"; return 1
}
# Masks both tokens in a string. The patterns are quoted, so they match literally.
scrub() {
  local s=$1 mark='***'
  s=${s//"$op_token"/$mark}
  s=${s//"$gw_token"/$mark}
  printf '%s' "$s"
}
# The last five lines of what a failed item printed, masked and cut short; the reason comes last.
show_failure() {
  local text
  text=$(scrub "$OUT"$'\n'"$ERR"$'\n'"$WHY")
  printf '%s\n' "$text" | sed '/^[[:space:]]*$/d' | tail -5 | cut -c1-200 | sed 's/^/       /'
}
# item NAME CHECK [ARGS]: PASS or FAIL, and on to the next whatever happened.
item() {
  local name=$1; shift
  OUT=""; ERR=""; RC=0; WHY=""
  if "$@"; then echo "PASS   $name"
  else echo "FAIL   $name"; show_failure; fail=$((fail + 1)); fi
}
manual() { echo "MANUAL $1"; }
strip_ansi() { OUT=$(printf '%s' "$OUT" | sed $'s/\033\\[[0-9;]*m//g'); }

# --- the checks ---------------------------------------------------------------------------------------
# Spec 2026-10-02 success criterion 1: this account cannot become root, so it cannot change the egress firewall.
check_no_root() {
  local nft
  run sudo -n true
  [ "$RC" -ne 0 ] || { WHY="sudo -n true succeeded: $(id -un) can become root"; return 1; }
  run sudo -n -l
  [ "$RC" -ne 0 ] || { WHY="sudo -n -l lists commands $(id -un) may run without a password"; return 1; }
  nft=$(PATH="$PATH:/usr/sbin:/sbin"; command -v nft) \
    || { WHY="nft not found (provisioning installs nftables): cannot show that the firewall is out of reach"; return 1; }
  run "$nft" list table inet claw
  [ "$RC" -ne 0 ] || { WHY="$(id -un) can read the inet claw table, so it holds CAP_NET_ADMIN and could change it"; return 1; }
}

# Every bot process runs as this account: the gateway's main process, and nothing that looks like the bot under any
# other uid (an admin gateway left running would be two gateways on one WhatsApp identity).
check_bot_owner() {
  local pid owner me others="" uid args
  me=$(id -u)
  produce systemctl --user show openclaw-gateway.service -p MainPID --value || return 1
  pid=$(printf '%s' "$OUT" | tr -d '[:space:]')
  [[ $pid =~ ^[1-9][0-9]*$ ]] || { WHY="the gateway has no main process (MainPID '$pid')"; return 1; }
  produce ps -o uid= -p "$pid" || return 1
  owner=$(printf '%s' "$OUT" | tr -d '[:space:]')
  [ "$owner" = "$me" ] || { WHY="the gateway (pid $pid) runs as uid ${owner:-unknown}, not $me"; return 1; }
  produce ps -eo uid=,args= || return 1
  while read -r uid args; do
    if [ -z "$uid" ] || [ "$uid" = "$me" ]; then continue; fi
    if [[ $args =~ $BOT_PROC_RE ]]; then others="$others uid $uid: ${args:0:80};"; fi
  done <<<"$OUT"
  [ -z "$others" ] || { WHY="bot processes of another account:$others"; return 1; }
}

check_secrets() {
  produce openclaw secrets audit --allow-exec || return 1
  matches 'unresolved=0,' "the audit summary does not say unresolved=0"
}

# A fresh npm install has no updater history (a package-manager install creates none), so `lastRun` is absent
# until `openclaw update` has run; the import also restores the old machine's history, whose last run is then
# what shows. So: a last run that exists must have succeeded, and either way the installed version must be at
# least the pin the guest was provisioned with (an `openclaw update` moves it past the pin; older, or unreadable,
# fails).
check_update() {
  local pin last installed
  pin=$(sed -n 's/^OPENCLAW_VERSION=//p' "$here/../provision/versions.env" 2>/dev/null)
  [ -n "$pin" ] || { WHY="no OPENCLAW_VERSION in provision/versions.env"; return 1; }
  produce openclaw update status --json || return 1
  last=$(jq -r 'if type == "object" then (.lastRun.status // "none") else "invalid" end' <<<"$OUT" 2>/dev/null)
  case "$last" in
    succeeded|none) ;;
    *) WHY="last update run is '${last:-not JSON}', want succeeded (or no run yet)"; return 1 ;;
  esac
  produce openclaw --version || return 1
  installed=$(sed -n 's/^OpenClaw \([^[:space:]]*\).*$/\1/p' <<<"$OUT")
  vercmp "$installed" "$pin" >/dev/null 2>&1 || { WHY="installed '${installed:-unreadable}' is not a version (the pin is '$pin')"; return 1; }
  version_ge "$installed" "$pin" || { WHY="installed '$installed' is older than the pin '$pin' in provision/versions.env"; return 1; }
}

# check_agent SESSION-KEY [OPTIONS]: one real turn through the Gateway; the reply text (either documented
# JSON shape) must say pong. Looking at the reply alone means an echo of the prompt cannot pass.
check_agent() {
  local key=$1; shift
  produce openclaw agent --agent main --session-key "$key" "$@" -m "Reply with exactly: pong" --json || return 1
  jq -e '[(.result.payloads // .payloads // [])[]? | .text? // empty] | join(" ") | ascii_downcase | contains("pong")' \
    <<<"$OUT" >/dev/null 2>&1 \
    || { WHY="the reply text (result.payloads[].text) does not say pong"; return 1; }
}

check_firewall() {
  produce bash "$here/firewall-check.sh" "$lan" || return 1
  matches '^firewall: OK$' "firewall-check.sh did not print 'firewall: OK'"
}

check_guard() {
  produce node "$HOME/ops/listener-guard/guard.mjs" --dry-run || return 1
  matches '^(ok: |\[dry-run\] )' "the guard printed neither 'ok:' nor a '[dry-run]' decision"
}

# The replay: the installed guard on the committed log, with a scratch state file, must find the stranded listener.
# A rehearsal guest has no WhatsApp link, and the guard asks for one before it restarts; "not linked" is reached
# only once the replay has found the stranded listener, so a rehearsal accepts it.
check_guard_replay() {
  local st want
  st=$(mktemp "${TMPDIR:-/tmp}/acceptance-guard.XXXXXX") || { WHY="cannot create a temp file"; return 1; }
  run env GUARD_LOG_DIR="$GUARD_FIXTURE" GUARD_STATE="$st" node "$HOME/ops/listener-guard/guard.mjs" --dry-run --now "$GUARD_REPLAY_AT"
  rm -f "$st"
  [ "$RC" -eq 0 ] || { WHY="exit $RC"; return 1; }
  if [ "$mode" = final ]; then want='^\[dry-run\] 2026-09-30T09:02:00\.000Z restart: stranded listener \(2 events\)$'
  else want='^\[dry-run\] 2026-09-30T09:02:00\.000Z (restart: stranded listener|skip: WhatsApp not linked) \(2 events\)$'; fi
  matches "$want" "the replay of the stranded-listener log did not decide to restart"
}

# Minor #41 on the guest: the installed guard refuses to act on replayed history. Its restart command is a stub here,
# so an older guard that would act restarts nothing.
check_guard_refuses() {
  local st mark ran=0
  st=$(mktemp "${TMPDIR:-/tmp}/acceptance-guard.XXXXXX") || { WHY="cannot create a temp file"; return 1; }
  mark="$st.restarted"
  run env GUARD_LOG_DIR="$GUARD_FIXTURE" GUARD_STATE="$st" GUARD_RESTART="touch '$mark'" node "$HOME/ops/listener-guard/guard.mjs" --now "$GUARD_REPLAY_AT"
  if [ -e "$mark" ]; then ran=1; fi
  rm -f "$st" "$mark"
  [ "$ran" = 0 ] || { WHY="the guard ran its restart command on replayed history"; return 1; }
  [ "$RC" -ne 0 ] || { WHY="the guard accepted --now without --dry-run (exit 0)"; return 1; }
  grep -q -- 'only runs with --dry-run' <<<"$ERR" || { WHY="the guard did not say why it refused (exit $RC)"; return 1; }
}

# The guard reads the gateway's log dir (GUARD_LOG_DIR in its unit). After an in-place move that dir must be this
# account's, with this account's logs in it: an earlier gateway's dir would leave the guard judging old lines.
check_gateway_log() {
  local unit="$HOME/.config/systemd/user/openclaw-listener-guard.service" dir f n=0
  dir=$(sed -n 's/^Environment=GUARD_LOG_DIR=//p' "$unit" 2>/dev/null | tail -1)
  [ -n "$dir" ] || dir=/tmp/openclaw
  [ -d "$dir" ] || { WHY="$dir does not exist: the gateway logs somewhere the guard does not read"; return 1; }
  [ -O "$dir" ] || { WHY="$dir belongs to another user (an earlier gateway's logs): the guard would read those, not this gateway's"; return 1; }
  for f in "$dir"/openclaw-*.log; do
    if [ -f "$f" ] && [ -O "$f" ]; then n=$((n + 1)); fi
  done
  [ "$n" -gt 0 ] || { WHY="no openclaw-<date>.log of this account in $dir"; return 1; }
}

# The memory index records its workspace and database as absolute paths: after a move to another home every one of
# them must be under this home (or printed relative to it).
check_memory_paths() {
  local p n=0 bad="" found path_re='[^[:space:]"=,()]*/\.openclaw[^[:space:]",()]*'
  produce openclaw memory status --agent main || return 1
  strip_ansi
  found=$(grep -oE -- "$path_re" <<<"$OUT" || true)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    n=$((n + 1))
    # shellcheck disable=SC2088  # a literal ~: OpenClaw may print a path relative to the home it runs in
    case "$p" in "$HOME"/.openclaw*|"~/.openclaw"*) ;; *) bad="$bad $p" ;; esac
  done <<<"$found"
  [ "$n" -gt 0 ] || { WHY="memory status printed no path under a .openclaw directory"; return 1; }
  [ -z "$bad" ] || { WHY="memory paths outside $HOME:$bad"; return 1; }
}

# timeout: an unanswered ssh prompt or a black-holed network must not hang the whole run.
check_vault() {
  produce timeout 60 git -C "$HOME/brain/vault" ls-remote origin HEAD || return 1
  matches '^[0-9a-f]{40,64}[[:space:]]+HEAD$' "ls-remote returned no HEAD"
}

# `channels status` exits 0 even with the Gateway down (config-only fallback), so the output decides.
check_whatsapp() {
  produce openclaw channels status || return 1
  strip_ansi
  matches "$WA_LINKED_RE" "the status has no linked, running, connected WhatsApp line"
}

check_wacli() {
  produce wacli auth status --read-only --json || return 1
  jq -e '.success == true and .data.authenticated == true' <<<"$OUT" >/dev/null 2>&1 \
    || { WHY="wacli does not report authenticated:true"; return 1; }
}

check_harvest() {
  produce cat "$HOME/brain/queue/harvest-health.json" || return 1
  matches '"ok"[[:space:]]*:[[:space:]]*true' 'harvest-health.json does not say "ok":true'
}

# --- the checklist --------------------------------------------------------------------------------------
item "privilege: the bot account cannot become root or touch the firewall" check_no_root
item "privilege: every bot process runs as the bot account" check_bot_owner
item "secrets audit: 0 unresolved" check_secrets
item "update status: no failed run, installed version is at least the pin" check_update
probes_started=1
item "agent probe: primary"  check_agent bench:acc-primary
item "agent probe: fallback" check_agent bench:acc-fallback --model openai/gpt-6-luna
item "firewall" check_firewall
item "listener guard dry run" check_guard
item "listener guard replays a stranded-listener log and would restart" check_guard_replay
item "listener guard refuses --now without --dry-run" check_guard_refuses
item "gateway log dir belongs to the bot account (the guard reads it)" check_gateway_log
item "memory index paths are under this home" check_memory_paths
item "vault remote reachable with deploy key" check_vault
# The probe sessions go whatever the probes did (item never stops at a FAIL); the EXIT trap covers an early end.
delete_probe_sessions

if [ "$mode" = final ]; then
  item "WhatsApp linked + connected" check_whatsapp
  item "wacli authenticated" check_wacli
  item "harvest health ok" check_harvest
fi
# Final review I-1: what no script can judge is printed, so it is confirmed and recorded, not forgotten.
manual "doctor shows no new warnings versus the pre-migration baseline (compare on a drill, with the gateway stopped: doctor writes)"
manual "memory search returns results: openclaw memory search <a word from a recent note> --agent main"
if [ "$mode" = final ]; then
  manual "one real WhatsApp message gets a reply"
  manual "first scheduled ocsb-ingest and one announce job succeed (openclaw automations list --json)"
  manual "face in gateway presence (host: the panel shows the face)"
  manual "voice round-trip: a voice-gateway chat.send gets a spoken reply"
  manual "ssh admin@<name> over Tailscale, and limactl shell claw from the host"
  manual "a vault commit pushed since cutover (git -C ~/brain/vault log -1 origin/HEAD)"
  manual "restore drill (README \"Restore\")"
fi

if [ "$fail" -eq 0 ]; then echo "acceptance ($mode): automated items PASS"; exit 0; fi
echo "acceptance ($mode): $fail automated item(s) FAILED"
exit 1
```

- [ ] **Step 4: Run the tests**

Run: `bash tests/acceptance.test.sh && PATH="/bin:$PATH" /bin/bash tests/acceptance.test.sh && make lint`
Expected: `acceptance script: 212 passed, 0 failed` both times, and no shellcheck output. The pin `the script has no IP address, user name or LAN default of its own` still passes (the 0/127 rule is written as first octets, not addresses).

- [ ] **Step 5: Prove the new items bite**

Temporarily make `check_gateway_log` skip its `[ -O "$dir" ]` line: "  ... saying whose logs the guard would read" must FAIL. Temporarily remove `|backup/nightly-backup\.sh` from `BOT_PROC_RE`: the `nightly-backup.sh` case must FAIL. Restore both.

- [ ] **Step 6: Commit**

```bash
git add tests/acceptance.sh tests/acceptance.test.sh
git commit -m "feat(acceptance): run as the bot; privilege, guard replay, log dir, memory items; I-1 MANUAL lines; reject 0.x/127.x" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The scripted in-place switch, `migrate/rehome.sh`

**Files:**
- Create: `migrate/rehome.sh`, `migrate/rehome.test.sh`
- Modify: `Makefile` (one line in `unit`)
- Test: `migrate/rehome.test.sh`

**Interfaces:**
- Consumes: `provision/bot.sh` (`BOT_USER`, `BOT_UID`, `BOT_HOME`, `BOT_SESSION`; Task 1), `import.sh final|drill <dir>` run as the bot (Task 4), `acceptance.sh final|rehearsal <lan-ip>` run as the bot (Task 7), the provisioned account (Task 2).
- Produces (Tasks 9-12 and the README use exactly these):
  - `bash /opt/vm-claw/migrate/rehome.sh prepare | switch final|drill | verify final|rehearsal <lan-ip> | retire | rollback`, run as `admin` (`host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh …`); exit 2 on bad usage, 1 on any refusal.
  - Records in `/var/lib/claw-rehome/` (root, 700): `switched` (`<mode> <ts> <night>`), `verified`, `retired` (the dir), `rolled-back-<ts>`.
  - Success lines: `prepare: OK (…)`, `switch: done (<mode>, <night>). Next: rehome.sh verify <final|rehearsal> <lan-ip>`, `verify: PASS. …`, `retire: admin's copy is in /var/lib/claw-retired-admin-<YYYYMMDD> (root only); delete it after <YYYY-MM-DD>`, `rollback: done; admin's gateway is active. …`.
  - The retired copy: `/var/lib/claw-retired-admin-<YYYYMMDD>/{home,units,RETIRED}`; `RETIRED` line 1 names the deletion date, the other lines the moved items relative to admin's home.
  - Aside dirs: admin's gateway logs `/tmp/openclaw.pre-rehome-<ts>`; on rollback admin's old WhatsApp state `~/.claw-rollback-aside-<ts>/`, the bot's copy `/home/sebastian/rehome-rolled-back-<ts>/`.

- [ ] **Step 1: Write the failing test**

Create `migrate/rehome.test.sh`:

```bash
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
mkdir -p "$t/repo/migrate" "$t/repo/tests" "$t/repo/provision" "$t/bin"
cp "$here/rehome.sh" "$t/repo/migrate/"; cp "$repo/provision/bot.sh" "$t/repo/provision/"
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
    fi ;;
  show) echo "${FAKE_NIGHTLY_RESULT:-success}" ;;
esac
exit 0
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
  unset FAKE_IMPORT_RC FAKE_ACC_RC FAKE_NIGHTLY_FAIL FAKE_NIGHTLY_RESULT FAKE_NIGHT_TS FAKE_STUCK FAKE_SUDO_LIST FAKE_BOT_IDS FAKE_BOT_LINGER FAKE_TS_OPERATOR FAKE_DF_AVAIL_KB TS || true
  rm -rf "$A" "$B" "$t/varlib" "$t/sd" "$t/gwlog" "$t"/gwlog.*; : > "$t/ev"
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
    FAKE_TS="${TS:-20261002T120000Z}" FAKE_DAY=20261002 FAKE_DEL=2026-10-16 \
    REHOME_VARLIB="$t/varlib" REHOME_GW_LOGDIR="$t/gwlog" PATH="$t/bin:$PATH" \
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
refuses "a retired copy next to admin's own state is left to the owner" "decide by hand" rollback

echo "rehome tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash migrate/rehome.test.sh`
Expected: exit non-zero: `cp: …/migrate/rehome.sh: No such file or directory` (the script does not exist yet).

- [ ] **Step 3: Write `migrate/rehome.sh`**

```bash
#!/bin/bash
# Run in the guest as admin (Lima's login user, with sudo), from the deployed repo:
#   host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh <phase>
# Moves the bot from admin to the unprivileged bot account in place
# (docs/superpowers/specs/2026-10-02-bot-user-sebastian-design.md §2). The phases, in order; each refuses when the
# one before it has not completed:
#   prepare                          pre-flight while production runs; changes nothing
#   switch final|drill               the downtime: admin's units off and proven off, one nightly with the gateway
#                                    stopped, that nightly copied to the bot's ~/claw-import, import.sh as the bot
#   verify final|rehearsal <lan-ip>  tests/acceptance.sh as the bot; a pass is recorded for retire
#   retire                           after a recorded pass: admin's bot data and units to
#                                    /var/lib/claw-retired-admin-<date>/ (root only), admin's linger off
#   rollback                         the bot's units off and proven off, its WhatsApp state carried back to admin
#                                    (admin's own set aside first), admin's units on; from the retired copy if retire ran
# Never two gateways: admin's gateway is proven down before the bot's starts, and the bot's before admin's restarts.
# Knobs for migrate/rehome.test.sh only: REHOME_VARLIB (default /var/lib), REHOME_GW_LOGDIR (default /tmp/openclaw).
set +x   # import.sh and the nightly handle tokens: a traced run must not print them
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
# shellcheck source=provision/bot.sh
. "$repo/provision/bot.sh"
varlib="${REHOME_VARLIB:-/var/lib}"
state="$varlib/claw-rehome"            # root-only record of what each phase completed
gwlog="${REHOME_GW_LOGDIR:-/tmp/openclaw}"
me=$(id -un)
die() { echo "rehome: $*" >&2; exit 1; }
usage() { echo "usage: $0 prepare | switch final|drill | verify final|rehearsal <lan-ip> | retire | rollback" >&2; exit 2; }
# The guard goes first (a guard run in flight can restart the gateway), the gateway last; started the other way round.
STOP_UNITS=(openclaw-listener-guard.timer openclaw-listener-guard.service openclaw-nightly-backup.timer openclaw-gateway.service)
START_UNITS=(openclaw-gateway.service openclaw-listener-guard.timer openclaw-nightly-backup.timer)
# What the bot is, relative to a home (spec §2 step 6), and the aside, stale and retired dirs of earlier imports.
BOT_ITEMS=(.openclaw brain .wacli ops backups claw-import .local/state/claw)
BOT_GLOBS=('.openclaw.pre-import-*' '.openclaw-stale-*' 'openclaw-agents-retired-*')

as_bot() { "${BOT_SESSION[@]}" "$@"; }
# As admin, a test inside the bot's mode-700 home fails for want of permission, which reads as "absent". Every look
# at the bot's files goes through sudo.
bot_has() { sudo -n test -e "$1"; }
mark() { printf '%s\n' "$2" | sudo -n tee "$state/$1" >/dev/null; }   # mark <name> <line>: record a phase as done
marked() { sudo -n test -f "$state/$1"; }
mark_value() { sudo -n cat "$state/$1"; }
acc_mode() { if [ "$1" = final ]; then echo final; else echo rehearsal; fi; }   # acceptance knows final|rehearsal
num() { local s="${1#claw-nightly-}"; s="${s%Z}"; printf '%s' "${s/T/}"; }      # claw-nightly-20261002T120000Z -> 20261002120000

# stop_units admin|bot: disable --now, then prove each is exactly inactive or failed ("activating" is neither).
stop_units() {
  local who="$1" u st
  for u in "${STOP_UNITS[@]}"; do
    if [ "$who" = bot ]; then as_bot systemctl --user disable --now "$u" >/dev/null 2>&1 || true
    else systemctl --user disable --now "$u" >/dev/null 2>&1 || true; fi
  done
  for u in "${STOP_UNITS[@]}"; do
    if [ "$who" = bot ]; then st=$(as_bot systemctl --user is-active "$u" 2>/dev/null || true)
    else st=$(systemctl --user is-active "$u" 2>/dev/null || true); fi
    case "$st" in
      inactive|failed) ;;
      *) die "$who's $u is '${st:-unknown}' after disable --now; refusing to go on (two gateways must never share WhatsApp)" ;;
    esac
  done
  echo "rehome: $who's gateway, guard and nightly timer are stopped and disabled"
}

prepare() {
  local out mode op d newest nk sk need avail u
  [ "$(getent passwd "$BOT_USER" | cut -d: -f3,4,6)" = "$BOT_UID:$BOT_UID:$BOT_HOME" ] \
    || die "$BOT_USER is not $BOT_UID:$BOT_UID with home $BOT_HOME (run host/claw.sh provision)"
  out=$(LC_ALL=C sudo -n -l -U "$BOT_USER" 2>&1 || true)
  grep -qF 'is not allowed to run sudo' <<<"$out" || die "$BOT_USER may run sudo: the move would gain nothing (fix sudoers by hand)"
  [ "$(loginctl show-user "$BOT_USER" -p Linger 2>/dev/null || true)" = Linger=yes ] \
    || die "$BOT_USER has no linger: its units would not start at boot (run host/claw.sh provision)"
  if bot_has "$BOT_HOME/.openclaw"; then die "$BOT_HOME/.openclaw exists already: a switch ran before (rehome.sh rollback moves it aside)"; fi
  if bot_has "$BOT_HOME/.ssh/authorized_keys"; then die "$BOT_HOME/.ssh/authorized_keys exists: the bot account must have no SSH login"; fi
  as_bot test -r "$repo/migrate/import.sh" || die "$BOT_USER cannot read $repo (deploy it with host/claw.sh deploy)"
  [ -f "$HOME/.openclaw/openclaw.json" ] || die "$HOME/.openclaw/openclaw.json is missing: nothing to move"
  for u in openclaw-gateway.service openclaw-nightly-backup.service; do
    [ -f "$HOME/.config/systemd/user/$u" ] || die "admin has no $u: the switch needs admin's gateway and its nightly"
  done
  mode=$(node -e 'const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String(c?.gateway?.tailscale?.mode ?? ""))' "$HOME/.openclaw/openclaw.json") \
    || die "cannot read gateway.tailscale.mode from $HOME/.openclaw/openclaw.json"
  case "$mode" in
    serve|funnel)
      op=$(tailscale debug prefs 2>/dev/null | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0, "utf8")).OperatorUser ?? ""))' 2>/dev/null || true)
      [ "$op" = "$BOT_USER" ] \
        || die "gateway.tailscale.mode=$mode needs Tailscale's operator to be $BOT_USER, not '${op:-none}' (host/claw.sh provision sets it once Tailscale is up)" ;;
  esac
  # Room for the switch: one more nightly, its copy in the bot's claw-import, and the restored state (about the size
  # of ~/.openclaw), plus 1 GiB.
  newest=""
  for d in "$HOME"/backups/claw-nightly-*Z; do if [ -d "$d" ]; then newest="$d"; fi; done
  nk=0
  if [ -n "$newest" ]; then nk=$(du -sk "$newest" | awk '{ print $1 }'); fi
  sk=$(du -sk "$HOME/.openclaw" | awk '{ print $1 }')
  need=$((2 * nk + sk + 1048576))
  avail=$(df -Pk "$HOME" | awk 'NR == 2 { print $4 }')
  [ "${avail:-0}" -ge "$need" ] \
    || die "not enough free space in $HOME: $((need / 1024)) MiB needed (two nightlies, ~/.openclaw and 1 GiB), $((${avail:-0} / 1024)) MiB free"
  echo "prepare: OK ($BOT_USER is ready; production untouched)"
}

switch() {
  local mode="$1" ts night copy n d
  prepare
  if marked switched; then die "a switch is already recorded ($(mark_value switched)): rehome.sh rollback first"; fi
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  sudo -n install -d -m 700 "$state"
  # 1. admin's gateway, guard and nightly timer: off, and proven off.
  stop_units admin
  # The gateway logs under $gwlog and the guard reads it. Left as admin's, the bot's gateway would log elsewhere and
  # the guard would judge admin's old lines: set admin's aside; the bot's gateway makes its own.
  if [ -e "$gwlog" ]; then sudo -n mv "$gwlog" "$gwlog.pre-rehome-$ts"; echo "rehome: admin's gateway logs moved to $gwlog.pre-rehome-$ts"; fi
  # 2. One nightly with the gateway stopped: a consistent snapshot, and the newest there is.
  systemctl --user start openclaw-nightly-backup.service \
    || die "the nightly backup failed (journalctl --user -u openclaw-nightly-backup.service); admin's data is untouched: rehome.sh rollback"
  [ "$(systemctl --user show -p Result --value openclaw-nightly-backup.service)" = success ] \
    || die "the nightly backup did not end in success; admin's data is untouched: rehome.sh rollback"
  night=""
  for d in "$HOME"/backups/claw-nightly-*Z; do
    n=$(basename "$d")
    if [ -d "$d" ] && [ "$(num "$n")" -ge "$(num "claw-nightly-$ts")" ] 2>/dev/null; then night="$n"; fi
  done
  [ -n "$night" ] || die "no nightly from this switch ($ts or later) in $HOME/backups: refusing to import an older snapshot; rehome.sh rollback"
  # 3. The bot's own copy, mode 700, in its home. admin's ~/backups stays as it is.
  sudo -n install -d -m 700 -o "$BOT_USER" -g "$BOT_USER" "$BOT_HOME/claw-import"
  copy="$BOT_HOME/claw-import/$night"
  if bot_has "$copy"; then die "$copy exists already"; fi
  sudo -n cp -a "$HOME/backups/$night" "$copy"
  sudo -n chown -R "$BOT_USER:$BOT_USER" "$copy"
  sudo -n chmod 700 "$copy"
  sudo -n find "$copy" -type f -exec chmod 600 {} +
  mark switched "$mode $ts $night"
  # 4. The import, as the bot.
  as_bot bash "$repo/migrate/import.sh" "$mode" "$copy" \
    || die "import.sh $mode failed (see above); admin's data is untouched: rehome.sh rollback, fix, then switch again"
  echo "switch: done ($mode, $night). Next: rehome.sh verify $(acc_mode "$mode") <lan-ip>"
}

verify() {
  local amode="$1" lan="$2" smode
  marked switched || die "no switch is recorded: run rehome.sh switch first"
  smode=$(mark_value switched | cut -d' ' -f1)
  [ "$(acc_mode "$smode")" = "$amode" ] || die "the recorded switch is '$smode': verify it as '$(acc_mode "$smode")'"
  if as_bot bash "$repo/tests/acceptance.sh" "$amode" "$lan"; then
    mark verified "$amode $(date -u +%Y%m%dT%H%M%SZ)"
    echo "verify: PASS. The owner confirms the MANUAL lines above; then rehome.sh retire"
  else
    die "acceptance FAILED (see above): fix forward, or rehome.sh rollback"
  fi
}

retire() {
  local st day dest del it g p
  local -a moved=()
  marked verified || die "no passing verify is recorded: run rehome.sh verify first"
  st=$(as_bot systemctl --user is-active openclaw-gateway.service 2>/dev/null || true)
  [ "$st" = active ] || die "the bot's gateway is '${st:-unknown}', not active: admin's copy stays where it is"
  stop_units admin
  day=$(date -u +%Y%m%d)
  dest="$varlib/claw-retired-admin-$day"
  if sudo -n test -e "$dest"; then die "$dest exists already"; fi
  # What goes: the bot's dirs, the aside/stale/retired dirs of earlier imports, everything in admin's ~/.ssh except
  # authorized_keys (admin's own login stays; the vault deploy key is the bot's), and the timer stamps.
  for it in "${BOT_ITEMS[@]}"; do if [ -e "$HOME/$it" ]; then moved+=("$it"); fi; done
  for g in "${BOT_GLOBS[@]}"; do
    # shellcheck disable=SC2231  # $g is a glob on purpose
    for p in "$HOME"/$g; do if [ -e "$p" ]; then moved+=("${p#"$HOME"/}"); fi; done
  done
  for p in "$HOME"/.ssh/* "$HOME"/.local/share/systemd/timers/stamp-openclaw-*; do
    if [ -e "$p" ] && [ "$p" != "$HOME/.ssh/authorized_keys" ]; then moved+=("${p#"$HOME"/}"); fi
  done
  [ "${#moved[@]}" -gt 0 ] || die "nothing of the bot's is left in $HOME: retired already?"
  sudo -n install -d -m 700 -o root -g root "$dest" "$dest/home" "$dest/units"
  for it in "${moved[@]}"; do
    sudo -n mkdir -p "$dest/home/$(dirname "$it")"
    sudo -n mv "$HOME/$it" "$dest/home/$it"
  done
  for p in "$HOME"/.config/systemd/user/openclaw-*.service "$HOME"/.config/systemd/user/openclaw-*.timer; do
    if [ -e "$p" ]; then sudo -n mv "$p" "$dest/units/"; fi
  done
  systemctl --user daemon-reload
  sudo -n loginctl disable-linger "$me"
  del=$(date -u -d "+14 days" +%Y-%m-%d)
  { printf 'retired %s from %s; delete after %s (README "Retire")\n' "$day" "$HOME" "$del"; printf '%s\n' "${moved[@]}"; } \
    | sudo -n tee "$dest/RETIRED" >/dev/null
  for it in "${moved[@]}"; do if [ -e "$HOME/$it" ]; then die "$HOME/$it is still there after the move"; fi; done
  mark retired "$dest"
  echo "retire: admin's copy is in $dest (root only); delete it after $del"
}

rollback() {
  local ts src="" n=0 r st aside it p u wa carried=0 baside
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  sudo -n install -d -m 700 "$state"
  for r in "$varlib"/claw-retired-admin-*; do
    if sudo -n test -d "$r"; then n=$((n + 1)); src="$r"; fi
  done
  [ "$n" -le 1 ] || die "more than one retired copy in $varlib (claw-retired-admin-*): restore one by hand (README \"Rollback\")"
  if [ -n "$src" ] && [ -e "$HOME/.openclaw" ]; then die "both $HOME/.openclaw and $src exist: decide by hand which one is admin's (README \"Rollback\")"; fi
  if [ -z "$src" ] && [ ! -f "$HOME/.openclaw/openclaw.json" ]; then die "neither $HOME/.openclaw nor a retired copy exists: nothing to roll back to"; fi
  # 1. The bot's units off, and proven off: from here on no gateway runs.
  stop_units bot
  # 2. admin's data back in place, if retire moved it (root's mv keeps admin as the owner).
  if [ -n "$src" ]; then
    while IFS= read -r it; do
      [ -n "$it" ] || continue
      if [ -e "$HOME/$it" ]; then die "$HOME/$it exists; not overwriting it with the retired copy"; fi
      mkdir -p "$HOME/$(dirname "$it")"
      sudo -n mv "$src/home/$it" "$HOME/$it"
    done < <(sudo -n sed -n '2,$p' "$src/RETIRED")
    mkdir -p "$HOME/.config/systemd/user"
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      sudo -n mv "$src/units/$u" "$HOME/.config/systemd/user/$u"
    done < <(sudo -n ls -A "$src/units")
    [ -z "$(sudo -n find "$src/home" -mindepth 1 ! -type d -print)" ] || die "files are left in $src/home after the restore; look before deleting it"
    sudo -n rm -rf "$src"
    sudo -n loginctl enable-linger "$me"
    echo "rehome: admin's copy is back from $src"
  fi
  # 3. The bot's WhatsApp state is newer than admin's (its gateway ran since the switch). admin's own set goes aside
  #    first, -wal and -shm included, so nothing stale mixes with it; then the bot's is copied over, as admin's.
  # shellcheck disable=SC2016  # expanded by root's bash
  wa=$(sudo -n bash -c 'cd "$1" 2>/dev/null && { ls -d .openclaw/credentials/whatsapp* .wacli/session.db* 2>/dev/null || true; }' _ "$BOT_HOME")
  if [ -n "$wa" ]; then
    aside="$HOME/.claw-rollback-aside-$ts"
    mkdir -m 700 "$aside"
    for p in "$HOME"/.openclaw/credentials/whatsapp* "$HOME"/.wacli/session.db*; do
      if [ -e "$p" ]; then mkdir -p "$aside/$(dirname "${p#"$HOME"/}")"; mv "$p" "$aside/${p#"$HOME"/}"; fi
    done
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      mkdir -p "$HOME/$(dirname "$p")"
      sudo -n cp -a "$BOT_HOME/$p" "$HOME/$p"
      sudo -n chown -R "$me:$(id -gn)" "$HOME/$p"
      carried=$((carried + 1))
    done <<<"$wa"
    echo "rehome: carried $carried WhatsApp item(s) back to admin; admin's earlier ones are in $aside"
  fi
  # 4. The bot's copy out of the way: it lingers, so nothing may start on it, and a later switch starts clean.
  baside="$BOT_HOME/rehome-rolled-back-$ts"
  sudo -n install -d -m 700 -o "$BOT_USER" -g "$BOT_USER" "$baside" "$baside/units"
  for it in "${BOT_ITEMS[@]}"; do
    if bot_has "$BOT_HOME/$it"; then sudo -n mkdir -p "$baside/$(dirname "$it")"; sudo -n mv "$BOT_HOME/$it" "$baside/$it"; fi
  done
  # shellcheck disable=SC2016  # expanded by root's bash
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    sudo -n mv "$BOT_HOME/.config/systemd/user/$u" "$baside/units/$u"
  done < <(sudo -n bash -c 'cd "$1" 2>/dev/null && { ls -d openclaw-*.service openclaw-*.timer 2>/dev/null || true; }' _ "$BOT_HOME/.config/systemd/user")
  sudo -n chown -R "$BOT_USER:$BOT_USER" "$baside"
  as_bot systemctl --user daemon-reload >/dev/null 2>&1 || true
  if [ -e "$gwlog" ]; then sudo -n mv "$gwlog" "$gwlog.rolled-back-$ts"; fi
  # 5. admin's units on again.
  systemctl --user daemon-reload
  for u in "${START_UNITS[@]}"; do
    if [ -f "$HOME/.config/systemd/user/$u" ]; then
      systemctl --user reset-failed "$u" >/dev/null 2>&1 || true
      systemctl --user enable --now "$u"
    fi
  done
  st=""
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    st=$(systemctl --user is-active openclaw-gateway.service 2>/dev/null || true)
    if [ "$st" = active ]; then break; fi
    sleep 2
  done
  [ "$st" = active ] || die "admin's gateway is '${st:-unknown}' after the rollback (journalctl --user -u openclaw-gateway.service)"
  sudo -n rm -f "$state/switched" "$state/verified" "$state/retired"
  if [ -n "$src" ]; then mark "rolled-back-$ts" "from $src"; else mark "rolled-back-$ts" "from admin's home"; fi
  echo "rollback: done; admin's gateway is active. Check WhatsApp: openclaw channels status (linked, running, connected)"
}

[ "$(id -u)" != 0 ] || die "run as admin, not as root"
[ "$me" != "$BOT_USER" ] || die "run as admin, not as $BOT_USER"
case "${1:-}" in
  prepare)  [ "$#" -eq 1 ] || usage; prepare ;;
  switch)   [ "$#" -eq 2 ] || usage; case "$2" in final|drill) ;; *) usage ;; esac; switch "$2" ;;
  verify)   [ "$#" -eq 3 ] || usage; case "$2" in final|rehearsal) ;; *) usage ;; esac; verify "$2" "$3" ;;
  retire)   [ "$#" -eq 1 ] || usage; retire ;;
  rollback) [ "$#" -eq 1 ] || usage; rollback ;;
  *) usage ;;
esac
```

- [ ] **Step 4: Add the suite to `make unit`**

In `Makefile`, after the line `	@bash migrate/import.test.sh`, add:

```make
	@bash migrate/rehome.test.sh
```

- [ ] **Step 5: Run the tests**

Run: `bash migrate/rehome.test.sh && PATH="/bin:$PATH" /bin/bash migrate/rehome.test.sh && make lint && make unit`
Expected: `rehome tests: 65 passed, 0 failed` twice, no shellcheck output, and `make unit` passes.

- [ ] **Step 6: Prove the guard rails bite**

One at a time, run the suite after each temporary change, then restore it: drop `stop_units bot` from `rollback` ("the bot's units were stopped and proven off …" FAILs); move step 3 of `rollback` after step 5 ("… carried to admin before admin's gateway starts" FAILs); replace `bot_has "$BOT_HOME/.openclaw"` in `prepare` with `[ -e "$BOT_HOME/.openclaw" ]` ("… looked inside the bot's home through sudo" FAILs); remove the `if [ -e "$gwlog" ]` line from `switch` ("admin's gateway logs were set aside …" FAILs).

- [ ] **Step 7: Commit**

```bash
git add migrate/rehome.sh migrate/rehome.test.sh Makefile
git commit -m "feat(migrate): rehome.sh, the in-place switch to the bot account, with rollback and retire" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Runbook and agent guidance for the two-account layout (I-3, I-4, I-1)

**Files:**
- Modify: `README.md` (whole file), `CLAUDE.md` (whole file), `lima/claw.yaml:15-19` (comments only), `docs/verification.md` (a new section after the first table, before `## Notes`)

**Interfaces:**
- Consumes: every command name from Tasks 1-8: `host/claw.sh … sebastian -- <cmd> | deploy | provision`, `CLAW_INSTANCE`, `migrate/rehome.sh prepare|switch|verify|retire|rollback`, `import.sh` as the bot, `tests/acceptance.sh` as the bot, `/var/lib/claw-retired-admin-<date>/RETIRED`, `~/.claw-rollback-aside-<ts>`, `/home/sebastian/rehome-rolled-back-<ts>`.
- Produces: README sections that Tasks 10-12 follow and record against: "Move the bot to its own account", "Restore", "Rehearse", "Rebuild", "Restore from restic", "Rollback" (two subsections), "Retire".

- [ ] **Step 1: Rewrite `README.md`**

Replace the whole file with:

````markdown
# vm-claw

A security-isolated Linux VM that runs an [OpenClaw](https://github.com/openclaw/openclaw) gateway on a Mac mini host. The VM is a [Lima](https://lima-vm.io) instance named `claw` (Debian 13 arm64, `vz` backend, 4 vCPU, 8 GiB RAM, UTC). It replaced a Tart macOS VM on 2026-10-01, and on 2026-10-02 the bot moved to its own unprivileged account. The designs are `docs/superpowers/specs/2026-09-30-linux-vm-migration-design.md` and its addendum `docs/superpowers/specs/2026-10-02-bot-user-sebastian-design.md`; the facts the build relies on are in `docs/verification.md`.

This repo is public. It holds no secrets, IPs, phone numbers, WhatsApp JIDs, account names or key fragments, and neither may anything you add to it. Placeholders in this file: `<host>` is the Mac mini's SSH target, `<lan-router-ip>` is any address on the home LAN (used only to prove the guest cannot reach it), `<owner-number>` is the owner's WhatsApp number, `<name>` is the guest's Tailscale hostname, `<ts>` is a nightly's UTC timestamp (`20261002T033000Z`), `<date>` is a day (`20261002`).

## Overview

Isolation properties, each enforced in `lima/claw.yaml` or by provisioning and each checked by a script in `tests/`:

- No host mounts (`mounts: []`; Lima mounts the host home by default).
- Exactly one port forward: guest `127.0.0.1:18789` to host `127.0.0.1:18789`, then a catch-all ignore (Lima forwards every listening port by default). The appliance face connects to `ws://127.0.0.1:18789` through it.
- NAT only: the guest has no LAN address.
- Guest egress firewall (nftables): RFC1918 and link-local are dropped; loopback, established traffic, DNS and DHCP to Lima's gateway, the internet and Tailscale's `100.64.0.0/10` are allowed.
- No GUI, so no clipboard. `sshd` is key-only.
- Backups leave the VM by a host-to-guest pull only; the guest has no write access to the host.

Two accounts in the guest:

- `admin` is Lima's login and maintenance user: `limactl shell`, `ssh admin@<name>` over Tailscale, provisioning. It has passwordless sudo (Lima's cloud-init) and its home is `/Users/admin`. It owns no bot data and no bot units.
- `sebastian` is the bot: UID and GID 2000, home `/home/sebastian` at mode 700, password locked, its own group only, no sudo, no SSH login (`DenyUsers sebastian`, no `authorized_keys`). The gateway, the agent's tools, the listener guard and the nightly backup run as its systemd user units; linger starts them at boot without a login. It owns `~/.openclaw`, `~/brain` (the vault, with its deploy key in `~/.ssh`), `~/.wacli`, `~/ops` and `~/backups`.
- The bot cannot become root, so the egress firewall holds against the agent too: only root can change the `inet claw` table. `tests/acceptance.sh` proves both on every run.
- Tailscale's operator is `sebastian`, so the gateway manages its own Serve claim (`gateway.tailscale.mode=serve`) without root. `tailscaled` stays a root service.
- The repo is deployed at `/opt/vm-claw`, root-owned and read-only for everyone else. The bot runs its scripts from there.

Pinned versions (`provision/versions.env`): OpenClaw `2026.9.7` (a floor), node major `24`, wacli `0.13.0`, sag `0.4.0`.

## Layout

```
Makefile                                 lint (shellcheck) + unit (node --test and the bash suites)
lima/claw.yaml                           VM definition
host/claw.sh                             host wrapper: create | deploy | provision | start | stop | shell | sebastian | destroy
host/install.sh                          host setup: Lima, restic, the backup pull agent (re-runnable)
host/pull-backups.sh                     host: pull the bot's nightlies, keep 14, restic off-site
host/local.vm-claw.pull-backups.plist    host launchd schedule for pull-backups.sh
provision/bot.sh                         the bot account: name, ids, home, the user-session prefix
provision/lib.sh                         step and assert helpers + change counter
provision/versions.env                   pinned versions and release checksums
provision/nftables.conf.tmpl             egress firewall template
provision/provision.sh                   guest provisioning (root), idempotent
migrate/export.sh                        old Tart VM: backup + file-state + manifest
migrate/import.sh                        guest, as the bot: verify, restore, rewrite, gate, start
migrate/binpaths.mjs                     binary-path rewrite (pure functions + CLI)
migrate/homepaths.mjs                    old-home rewrite of live configuration (pure functions + CLI)
migrate/scan-refs.mjs                    free-text scan: Homebrew paths, macOS-only commands, an old home
migrate/rehome.sh                        the in-place move to the bot account: prepare | switch | verify | retire | rollback
ops/listener-guard/                      stranded-listener guard, its systemd user units, a replay fixture
ops/backup/                              guest nightly backup, its units, backup-health.mjs
ops/lib/dotenv-token.sh                  shared parser for the bootstrap token in ~/.openclaw/.env
tests/isolation-check.sh                 host-side: mounts, forwards, no LAN address
tests/firewall-check.sh                  guest-side: LAN blocked, internet + DNS OK
tests/stack-check.sh                     guest-side, as admin: pinned tools, the bot account, the deployed repo
tests/acceptance.sh                      guest-side, as the bot: the acceptance checklist
docs/verification.md                     verified facts and the rehearsal, switch and drill records
cmd/, internal/, go.mod                  legacy `vmclaw` Go CLI for the Tart VM, kept for rollback until Task 14
docs/legacy-tart/                        the Tart-era README and CLAUDE.md
```

The checkout can live at any path on the host; the pull agent's plist gets that path from `host/install.sh`'s own location. Until the branch is pushed, code reaches the host as a git bundle: `git bundle create <file> feat/linux-vm` on the dev Mac, then `git fetch <file> feat/linux-vm` on the host.

## Build

On a Mac with Lima (`brew install lima`):

```bash
host/claw.sh create            # 8 GiB by default; --memory <GiB> to change
host/claw.sh start
host/claw.sh provision         # deploys HEAD to /opt/vm-claw, then provisions as root; a second run changes nothing
host/claw.sh shell -- bash /opt/vm-claw/tests/stack-check.sh
tests/isolation-check.sh       # host side; exit 1 on any violation
host/claw.sh shell -- bash /opt/vm-claw/tests/firewall-check.sh <lan-router-ip>
```

`CLAW_INSTANCE=<instance>` in front of any host script (`host/claw.sh`, `host/install.sh`, `host/pull-backups.sh`, `tests/isolation-check.sh`) picks another instance, for a drill or a rebuild; the default is `claw`. Other `host/claw.sh` commands: `stop`, `destroy`, `deploy` (ships HEAD only: commit first), `shell [-- cmd]` (as admin) and `sebastian -- <cmd>` (as the bot, with `XDG_RUNTIME_DIR` and the D-Bus address set, so `systemctl --user`, `journalctl --user` and `openclaw` work). Inside the guest, admin reaches the bot with `sudo -iu sebastian`. Plain `limactl shell` and `ssh admin@<name>` land as admin, whose `systemctl --user` has none of the bot's units.

Never run git inside the guest: a worktree's `.git` file does not resolve there. The guest gets the repo only through `host/claw.sh deploy`. `import.sh` installs `ops/` into the bot's `~/ops`; a later change to `ops/` reaches it in two steps: `host/claw.sh deploy`, then copy the changed file as the bot, for example `host/claw.sh sebastian -- cp /opt/vm-claw/ops/listener-guard/guard.mjs ops/listener-guard/`, and `host/claw.sh sebastian -- systemctl --user daemon-reload` after a unit change.

Tailscale: `gateway.tailscale.mode=serve` needs a logged-in Tailscale in the guest, and the gateway will not start logged out. Join with:

```bash
host/claw.sh shell -- sudo tailscale up --hostname=<name> --advertise-tags=<same tag as the old node>
host/claw.sh provision         # again: it sets the Tailscale operator to sebastian once Tailscale is logged in
```

The same tag keeps the node under the same ACLs and without key expiry.

## Move the bot to its own account (in place, 2026-10-02)

The guest first ran the bot as admin. `migrate/rehome.sh` moves it in phases; each refuses when the one before has not completed. Run them as admin: `host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh <phase>`.

1. Before the downtime, with production running: `host/claw.sh provision` (creates `sebastian`, linger, `DenyUsers`, the Tailscale operator and `/opt/vm-claw`), `tests/stack-check.sh`, then `rehome.sh prepare`. Plan the downtime after the 09:00 backup check and well before the 03:30 UTC nightly.
2. `rehome.sh switch final` (the downtime starts): it stops and disables admin's gateway, guard and nightly timer and proves them inactive, sets admin's gateway logs aside, takes one nightly with the gateway stopped, copies it to `/home/sebastian/claw-import/`, and runs `import.sh final` as the bot. The import rewrites `/Users/admin` to `/home/sebastian` in live configuration, fails on anything left over, and installs no `authorized_keys`. Old transcripts keep their history.
3. `rehome.sh verify final <lan-router-ip>` runs `tests/acceptance.sh final` as the bot. The owner confirms the `MANUAL` lines. The downtime ends when it passes.
4. `rehome.sh retire` moves admin's copy to `/var/lib/claw-retired-admin-<date>/` (root only) and turns admin's linger off. Delete the copy after 14 days ("Retire").

Rehearse the whole sequence on a drill first, with `switch drill` and `verify rehearsal <lan-router-ip>`. Until `retire`, `rehome.sh rollback` takes under a minute; after it, within 14 days, `rehome.sh rollback` restores the retired copy ("Rollback").

## Migrate (from the Tart VM, 2026-10-01)

`migrate/export.sh rehearsal|final` runs on the old VM and writes `~/claw-export-<mode>-<UTC ts>/` (two archives and a `MANIFEST` that starts with `mode=<mode>`). `migrate/import.sh rehearsal|final|drill <export-dir> [--force]` runs in the guest as the bot (`host/claw.sh sebastian -- bash /opt/vm-claw/migrate/import.sh …`) and verifies every checksum before touching `$HOME`. It refuses to run as root or without the bot's user manager.

- `rehearsal`: the export must carry no WhatsApp credentials; cron stays off and Tailscale serve is switched off. No real archive passes it, because `openclaw backup` always includes `credentials/whatsapp`: rehearse with `drill` ("Rehearse").
- `final`: carries the WhatsApp and wacli credentials, cron stays on, and with serve configured it needs a running, logged-in Tailscale whose operator is the importing account. It refuses a `mode=rehearsal` archive and accepts `mode=nightly`.
- `drill`: restores any archive for a restore drill, strips both credential sets and disables cron before anything starts.
- An archive made under another home is rehomed: that home is rewritten to `$HOME` in live configuration (`migrate/homepaths.mjs`), anything still naming it in live configuration fails the import (`migrate/scan-refs.mjs --old-home`), and its `authorized_keys` is not installed.
- Re-running on a guest that already has state is refused without `--force`, which moves `~/.openclaw` aside.

Never run two gateways with the same WhatsApp credentials.

The cutover from Tart (about 6 minutes of downtime) ran as admin: the old VM's `export.sh final`, a safety copy on the host, the old Tailscale node renamed `<name>-tart`, the host's SSH gateway-tunnel launch agent and the Tart launch agent disabled (plists renamed to `.disabled`), the guest given 8 GiB and its node renamed `<name>`, the export copied into the guest and imported with `import.sh final`, `limactl autostart enable claw`, `host/install.sh`, then acceptance. A repeat after a rollback to Tart imports into the bot account instead (as in "Rebuild", steps 6 and 7).

`openclaw doctor --non-interactive` writes (it rewrote the macOS service definition). Run it only with the gateway stopped.

### Revoked keys

`openclaw models auth logout` clears only the shared auth store. Provider model-catalog cache rows (`cache_entries`, scope `plugin-model-catalog-v1`) and old `.bak` database snapshots can still hold an old key, and a first start on a new box can rebuild a profile from such a row. The import's `openclaw secrets audit --check` catches it. Clean up with the gateway stopped: delete the row, then `PRAGMA wal_checkpoint(TRUNCATE); VACUUM;`.

## Operate

**Backups.**

- Guest: the bot's `openclaw-nightly-backup.timer` runs `ops/backup/nightly-backup.sh` nightly into `/home/sebastian/backups/claw-nightly-<ts>` (the same layout as an export, `mode=nightly`, keep 7).
- Host: `host/install.sh` sets up Lima, restic and the `local.vm-claw.pull-backups` launchd agent (its plist carries `CLAW_INSTANCE`). `host/pull-backups.sh` lists the bot's backups and streams each missing night with `sudo -u sebastian tar` (the backups are the bot's, mode 700) into `~/Backups/vm-claw` (keep 14). A night is kept only if it holds exactly its three files and passes the checksum gate. Every night restic has no snapshot of goes to a restic repository in iCloud Drive as its own snapshot (a night whose backup failed is retried on the next run; set that folder to "Keep Downloaded"), and only after a fully successful run does the pull stamp `/home/sebastian/backups/.host-pull-ok`, as the bot. Run `host/install.sh` over `ssh -t`: storing the restic password prompts on the terminal, and a locked login keychain must be unlocked first.
- Backup growth: the nightlies are gzip'd tarballs, which restic can neither deduplicate across nights nor compress, so each retained night costs its full size (about 1.2 GB today). Forget keeps 14 daily, 8 weekly and 12 monthly snapshots, counted per night (`--group-by host`), so the repository settles at about 34 retained nights, roughly 40 GB at today's size, and grows with the nightly. "Keep Downloaded" mirrors the whole repository on the Mac mini's disk. Check the iCloud storage quota and the host's free disk before relying on it, and again when the nightly grows: a full quota stops the off-site copy without any check failing.
- Alert: `ops/backup/backup-health.mjs` checks both halves. It exits 0 when healthy, 1 with `BACKUP ALERT: ...` when a nightly or the host stamp is older than 30 h, missing or dated in the future, and 2 when it cannot read `~/backups`. An OpenClaw command automation runs it daily at 09:00 Europe/Amsterdam (created at cutover, not committed). The command is a wrapper that prints `NO_REPLY` when the check passes, so nothing is sent, and on any non-zero exit, crash or missing script prints the alert:

  ```bash
  out=$(node "$HOME/ops/backup/backup-health.mjs" 2>&1); rc=$?; if [ "$rc" -eq 0 ]; then echo NO_REPLY; else printf "BACKUP ALERT (exit %s): %s\n" "$rc" "$out"; fi
  ```

  The full invocation, with `$wrapper` holding the line above:

  ```bash
  openclaw automations add --name backup-health --display-name "Backup health" \
    --description "Daily check of guest nightly + host pull/restic stamp; silent when healthy, WhatsApps on any failure" \
    --cron "0 9 * * *" --tz Europe/Amsterdam --exact \
    --command "$wrapper" --timeout-seconds 120 \
    --announce --channel whatsapp --to "<owner-number>" \
    --declaration-key backup-health
  ```

  Check the live wrapper with `host/claw.sh sebastian -- openclaw automations list --json`.

**Upgrades.**

- Debian security: `unattended-upgrades` (installed by provisioning).
- OpenClaw: the CLI is a root-owned global npm install the bot cannot write, so `openclaw update` cannot replace it; an upgrade is a maintenance action as admin, behind a backup. Bump `OPENCLAW_VERSION` in `provision/versions.env` and commit, then:

  ```bash
  host/claw.sh sebastian -- systemctl --user stop openclaw-listener-guard.timer openclaw-gateway.service
  host/claw.sh provision                                    # the pin is a floor: installs the newer pin, never downgrades
  host/claw.sh sebastian -- openclaw doctor --non-interactive   # gateway stopped: doctor writes
  host/claw.sh sebastian -- systemctl --user start openclaw-gateway.service openclaw-listener-guard.timer
  host/claw.sh sebastian -- bash /opt/vm-claw/tests/acceptance.sh final <lan-router-ip>
  ```

  `tests/stack-check.sh` and the acceptance "update status" item pass at or above the pin.
- Debian major, about every two years: in place with `apt full-upgrade` as admin, or a rebuild ("Rebuild").
- Lima: `brew upgrade lima` on the host; `lima/claw.yaml` is unaffected.

**Reboots.** The host auto-logs in and `limactl autostart enable claw` starts the VM at login, so a host reboot or power cut recovers unattended. The bot's linger starts its gateway, guard and nightly timer without a login. The gateway unit restarts on failure, and the listener guard restarts it when the WhatsApp listener is stranded.

**Tests.** `make lint` (shellcheck), `make unit` (node tests plus the bash suites: import, rehome, backup, install, claw, acceptance, stack-check, vercmp), `make test` for both and the legacy Go tests. The bash suites also pass under `/bin/bash` 3.2.

## Restore

A nightly has the same layout as a final export, so `import.sh final` accepts `mode=nightly`. In place, as the bot:

```bash
host/claw.sh sebastian -- bash -c 'mkdir -p -m 700 ~/claw-import && cp -a ~/backups/claw-nightly-<ts> ~/claw-import/'
host/claw.sh sebastian -- bash /opt/vm-claw/migrate/import.sh final /home/sebastian/claw-import/claw-nightly-<ts> --force
```

- The copy comes first, so the retained backup is never the import's working copy. `--force` moves the current `~/.openclaw` to `~/.openclaw.pre-import-<ts>`, which holds credentials and several GB: delete it once the restore is accepted.
- The restore takes the WhatsApp credentials back to that night, which can force a relink. To keep the live set instead, with the gateway stopped, put the restored set aside and copy the live one back from the pre-import dir:

  ```bash
  host/claw.sh sebastian -- systemctl --user stop openclaw-listener-guard.timer openclaw-gateway.service
  host/claw.sh sebastian -- bash -c 'p=$(ls -d ~/.openclaw.pre-import-* | tail -1); a=~/wa-restored-aside; mkdir -m 700 "$a" && mv ~/.openclaw/credentials/whatsapp* "$a"/ && cp -a "$p"/credentials/whatsapp* ~/.openclaw/credentials/'
  host/claw.sh sebastian -- systemctl --user start openclaw-gateway.service openclaw-listener-guard.timer
  ```

- `import.sh drill <dir>` proves a backup restores without putting a second gateway on the WhatsApp devices. Run drills on a machine other than the appliance: there the host port 18789 belongs to production.
- Backups live in the bot's `~/backups` in the guest, in `~/Backups/vm-claw` on the host and in the restic repository ("Restore from restic").

## Rehearse

A drill restores a real nightly into the bot account of a scratch instance, with both WhatsApp credential sets stripped and cron off. On the dev Mac, never the appliance:

```bash
export CLAW_INSTANCE=claw-drill
host/claw.sh create --memory 8 && host/claw.sh start && host/claw.sh provision
host/claw.sh shell -- bash /opt/vm-claw/tests/stack-check.sh       # stack: OK; the Tailscale operator line is skipped
host/claw.sh shell -- mkdir -p -m 700 claw-import
limactl copy --backend=scp -r <host-backup-dir>/claw-nightly-<ts> "$CLAW_INSTANCE":claw-import/
host/claw.sh shell -- bash -c 'sudo install -d -m 700 -o sebastian -g sebastian /home/sebastian/claw-import && sudo cp -a ~/claw-import/claw-nightly-<ts> /home/sebastian/claw-import/ && sudo chown -R sebastian:sebastian /home/sebastian/claw-import && rm -rf ~/claw-import'
host/claw.sh sebastian -- bash /opt/vm-claw/migrate/import.sh drill /home/sebastian/claw-import/claw-nightly-<ts>
host/claw.sh sebastian -- bash /opt/vm-claw/tests/acceptance.sh rehearsal <lan-router-ip>
host/claw.sh destroy; unset CLAW_INSTANCE
```

The admin-side copy goes through `~/claw-import` because admin cannot write into the bot's home; `limactl copy` into an existing directory nests the copy in it (`docs/verification.md`). Delete the dev Mac's copy of the nightly afterwards: it holds live secrets.

## Rebuild

For a Debian major or a broken guest. The real path is a nightly taken with the gateway stopped, imported with `import.sh final` into a new instance. Lima cannot rename an instance, so the new one keeps its own name.

1. Stop the old guest's bot, and prove it stopped:

   ```bash
   host/claw.sh sebastian -- systemctl --user disable --now openclaw-listener-guard.timer openclaw-listener-guard.service openclaw-nightly-backup.timer openclaw-gateway.service
   host/claw.sh sebastian -- systemctl --user is-active openclaw-gateway.service openclaw-listener-guard.service   # both: inactive or failed
   ```

2. Take a nightly with the gateway stopped and pull it to the host: `host/claw.sh sebastian -- systemctl --user start openclaw-nightly-backup.service`, then `bash host/pull-backups.sh`.
3. Keep the old instance as the rollback: `limactl autostart disable claw; limactl stop claw`. It holds the WhatsApp credentials and must not start again while the new one runs. Or delete it (`host/claw.sh destroy`) and keep only the backups.
4. Build the new instance: `export CLAW_INSTANCE=claw-<new>`, then the "Build" commands (`create --memory 8`, `start`, `provision`, `stack-check.sh`, `isolation-check.sh`, `firewall-check.sh`).
5. Tailscale: remove or rename the old node first, then join the new one as `<name>` ("Build") and run `host/claw.sh provision` again for the operator.
6. Copy the nightly into the bot's `~/claw-import` the way "Rehearse" does, then `host/claw.sh sebastian -- bash /opt/vm-claw/migrate/import.sh final /home/sebastian/claw-import/claw-nightly-<ts>`.
7. `host/claw.sh sebastian -- bash /opt/vm-claw/tests/acceptance.sh final <lan-router-ip>`; the owner confirms the `MANUAL` lines.
8. On the host: `limactl autostart enable "$CLAW_INSTANCE"`, and `CLAW_INSTANCE=claw-<new> bash host/install.sh` over `ssh -t`, so the pull agent pulls from the new instance. From then on put `CLAW_INSTANCE=claw-<new>` in front of every host script.

## Restore from restic

When the host disk is lost, the restic repository in iCloud Drive is the only copy that survives. Its password is in the owner's Private 1Password vault (the value `host/install.sh` stores in the login keychain as `vm-claw-restic`). On a new or rebuilt host with the repo cloned, iCloud Drive on and `bash host/install.sh` run:

```bash
export RESTIC_REPOSITORY="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups/vm-claw-restic"
export RESTIC_PASSWORD_COMMAND="security find-generic-password -s vm-claw-restic -w"
restic snapshots --tag vm-claw                                   # one snapshot per night
mkdir -m 700 ~/vm-claw-restore
restic restore latest --tag vm-claw --target ~/vm-claw-restore
night=$(find ~/vm-claw-restore -type d -name 'claw-nightly-*Z' | sort | tail -1)
(cd "$night" && grep -v '^mode=' MANIFEST | shasum -a 256 --strict -c -)
```

The restore recreates the snapshot's absolute path under the target. With the checksums OK, follow "Rebuild" from step 4 with `$night` as the host-side night, then delete `~/vm-claw-restore`: it holds live secrets.

## Rollback

### Of the move to the bot account (until 14 days after `retire`)

```bash
host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh rollback
```

It refuses unless exactly one of admin's own state or one retired copy exists, then:

1. stops and disables the bot's gateway, guard and nightly timer, and proves them inactive;
2. if `retire` ran, moves admin's copy back from `/var/lib/claw-retired-admin-<date>/` and turns admin's linger on;
3. moves admin's `credentials/whatsapp*` and `.wacli/session.db*` (with `-wal` and `-shm`) aside to `~/.claw-rollback-aside-<ts>/`, then copies the bot's newer set over, as admin's;
4. sets the bot's copy and unit files aside in `/home/sebastian/rehome-rolled-back-<ts>/`, so nothing starts on them;
5. enables admin's gateway, guard and nightly timer and waits for the gateway.

Then check `openclaw channels status` as admin: WhatsApp linked, running, connected. Messages and sessions created only under the bot stay in its aside copy. The host pull reads the bot's backups, so after a rollback unload it (`launchctl bootout gui/$(id -u)/local.vm-claw.pull-backups`) until the switch is repeated; the 09:00 backup check then reports the stale host stamp after 30 h, as expected.

### To the Tart VM (until Task 14 of the 2026-09-30 plan, about 2026-10-15)

The old Tart VM stays stopped, not deleted, for two weeks after the cutover. Never let two gateways hold the same WhatsApp credentials, and move the credentials only while no gateway runs. If the move to the bot account was rolled back first, the bot is admin again: use `host/claw.sh shell --` and admin's paths in steps 1 and 2.

While the new guest is still running:

1. Stop the bot's gateway and its helpers, and prove both are down:

   ```bash
   host/claw.sh sebastian -- systemctl --user disable --now openclaw-listener-guard.timer openclaw-listener-guard.service openclaw-nightly-backup.timer openclaw-gateway.service
   host/claw.sh sebastian -- systemctl --user is-active openclaw-gateway.service openclaw-listener-guard.service
   ```

   Both lines must read `inactive` or `failed`. Stop here otherwise.
2. Copy the current WhatsApp and wacli state out to the host, into a new mode-700 directory (only the bot can read its home, so it is streamed):

   ```bash
   mkdir -m 700 -p <host-dir>/rollback-state
   host/claw.sh sebastian -- tar -cf - .openclaw/credentials .wacli | tar -xf - -C <host-dir>/rollback-state
   ```

   Only `credentials/whatsapp*` and `.wacli/session.db*` matter. Step 11 deletes the folder.
3. Rename the new node out of the way while it can still run commands: `host/claw.sh shell -- sudo tailscale set --hostname=<name>-lima`.

On the host:

4. Turn the new VM off: `limactl autostart disable claw; limactl stop claw`. Then unload the pull agent: `launchctl bootout gui/$(id -u)/local.vm-claw.pull-backups`.
5. Re-enable the old VM's launch agent, which boots it: `mv ~/Library/LaunchAgents/com.vm-claw.agent.plist.disabled ~/Library/LaunchAgents/com.vm-claw.agent.plist && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.vm-claw.agent.plist`.
6. As soon as SSH answers, unload the old gateway and guard, and prove they are gone:

   ```bash
   ssh admin@<name>-tart 'launchctl bootout gui/$(id -u)/local.openclaw-listener-guard; launchctl bootout gui/$(id -u)/ai.openclaw.gateway; launchctl print gui/$(id -u)/ai.openclaw.gateway; launchctl print gui/$(id -u)/local.openclaw-listener-guard'
   ```

   Both `launchctl print` calls must fail ("Could not find service"). The old gateway may have run for a few seconds at boot with its pre-cutover credentials; only one gateway was running then. If WhatsApp later shows logged out, relink with `openclaw channels login`.
7. If step 2 ran, move the old VM's stale files aside first, `-wal` and `-shm` included, so nothing merges, then copy the new state in:

   ```bash
   ssh admin@<name>-tart 'a=~/rollback-aside-$(date -u +%Y%m%dT%H%M%SZ); mkdir -m 700 "$a" "$a/credentials" "$a/wacli"; mv ~/.openclaw/credentials/whatsapp* "$a/credentials/"; mv ~/.wacli/session.db* "$a/wacli/"'
   scp -rp <host-dir>/rollback-state/.openclaw/credentials/whatsapp* admin@<name>-tart:.openclaw/credentials/
   scp -p <host-dir>/rollback-state/.wacli/session.db* admin@<name>-tart:.wacli/
   ```

8. Load the old gateway and guard again and check them: `ssh admin@<name>-tart 'launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.openclaw-listener-guard.plist; launchctl list | grep -E openclaw'`. Then `openclaw channels status` in the old VM must show WhatsApp linked, running and connected.
9. Rename the old node back: `ssh admin@<name>-tart 'sudo tailscale set --hostname=<name>'`.
10. Re-enable the host's gateway tunnel agent (its label carries the user name, so it is found by pattern): `for f in ~/Library/LaunchAgents/*ziel-gateway-tunnel.plist.disabled; do mv "$f" "${f%.disabled}"; launchctl bootstrap gui/$(id -u) "${f%.disabled}"; done`. Check that the face reconnects.
11. `rm -rf <host-dir>/rollback-state`.

State created only in the new VM (messages, sessions) is lost. The Tart clone `vm-claw-pre-linux` and the safety exports stay until Task 14.

## Retire

Fourteen days after `rehome.sh retire`, with no rollback:

```bash
host/claw.sh shell -- sudo head -1 /var/lib/claw-retired-admin-<date>/RETIRED      # names the deletion date
host/claw.sh sebastian -- bash /opt/vm-claw/tests/acceptance.sh final <lan-router-ip>
host/claw.sh shell -- sudo rm -rf /var/lib/claw-retired-admin-<date>
host/claw.sh sebastian -- rm -rf claw-import
```

After that `rehome.sh rollback` has nothing to roll back to; restore from a backup instead.

### Legacy Tart tooling

The `vmclaw` Go CLI (`cmd/`, `internal/`; `make build`, `make go-test`) manages the Tart VM: lifecycle, Tailscale and firewall setup, and `doctor` checks. Its documentation is in [`docs/legacy-tart/`](./docs/legacy-tart/README.md). It is kept only for the Tart rollback window and is deleted in Task 14.

## License

MIT
````

- [ ] **Step 2: Rewrite `CLAUDE.md`**

Replace the whole file with:

````markdown
# CLAUDE.md

Guidance for Claude Code (claude.ai/code) in this repository. The runbook is `README.md`; the designs are `docs/superpowers/specs/2026-09-30-linux-vm-migration-design.md` and its addendum `docs/superpowers/specs/2026-10-02-bot-user-sebastian-design.md`; verified facts are in `docs/verification.md`.

## Project

Shell and Node tooling that builds and operates a security-isolated Lima VM (`claw`, Debian 13 arm64, `vz`) running an OpenClaw gateway on a Mac mini host. It replaced a Tart macOS VM on 2026-10-01. In the guest the bot runs as the unprivileged account `sebastian`; `admin` is Lima's login and maintenance user.

## Commands

```bash
make lint                        # shellcheck on every .sh
make unit                        # node --test plus the bash suites (import, rehome, backup, install, claw, acceptance, stack-check, vercmp)
make test                        # lint + unit + go-test (the legacy vmclaw Go CLI)
host/claw.sh create|deploy|provision|start|stop|shell|destroy
host/claw.sh sebastian -- <cmd>  # a command as the bot, with its user-session environment
CLAW_INSTANCE=<name> host/...    # another instance (a drill, a rebuild); the default is claw
host/install.sh                  # host: Lima, restic, backup pull agent (run over ssh -t)
tests/isolation-check.sh         # host side
```

Run the bash suites under `/bin/bash` 3.2 too (macOS default), the scripts included: `PATH="/bin:$PATH" /bin/bash <suite>`. No `mapfile`, no associative arrays.

## Global constraints

- The repo is public: never commit secrets, IPs, phone numbers, WhatsApp JIDs, account names, job IDs, tailnet names or key fragments. Never commit identifiers. Scripts find things by pattern, not by hard-coded identifier; docs use placeholders such as `<host>`, `<lan-router-ip>`, `<owner-number>`, `<name>`.
- Two accounts in the guest. `admin` (home `/Users/admin`, passwordless sudo) is Lima's login and maintenance user and owns no bot data or units. The bot is `sebastian`: UID and GID 2000, home `/home/sebastian` at mode 700, password locked, its own group only, no sudo, no SSH login (`DenyUsers sebastian`, no `authorized_keys`), linger, Tailscale operator. Its name, ids and home live only in `provision/bot.sh`; scripts that run as the bot use `$HOME`.
- The guest's repo is `/opt/vm-claw`: root-owned, read-only for everyone else, put there only by `host/claw.sh deploy` (a `git archive` of HEAD). Never stage anything root will run in a directory the bot can write, such as `/tmp`.
- Look inside the bot's home only through `sudo` or as the bot: as admin, a test on a mode-700 directory fails for want of permission and reads as "absent".
- Guest timezone `UTC`.
- Pinned versions (`provision/versions.env`): OpenClaw `2026.9.7` (a floor: provisioning never downgrades), node major `24`, wacli `0.13.0`, sag `0.4.0`. OpenClaw upgrades are a maintenance action as admin (README "Upgrades"): the bot cannot write the global npm install.
- Isolation: `mounts: []`; exactly one port forward (guest `127.0.0.1:18789` to host `127.0.0.1:18789`); NAT only; guest egress to RFC1918/link-local dropped except DNS and DHCP to Lima's gateway. Only root can change the `inet claw` table, and the bot is not root.
- Never run two gateways with the same WhatsApp credentials. Rehearsal and drill imports exclude them and disable cron. `migrate/rehome.sh` proves admin's gateway down before the bot's starts, and the bot's down before admin's restarts.
- `import.sh final` refuses `mode=rehearsal`, accepts `mode=nightly` as final; `rehearsal` refuses an archive with WhatsApp credentials; `drill` strips them. From another home it rewrites that home in live configuration, fails on anything left over, and installs no `authorized_keys`. Do not loosen these.
- Never run git inside the guest (a worktree's `.git` file does not resolve there). Run `openclaw doctor --non-interactive` only with the gateway stopped: it writes.
- Never touch the live guest, the old VM, the appliance or a gateway from a docs or code task.
- OpenClaw posture (carried over from the Tart era, still true of the live config): the gateway binds to loopback and is reachable from the tailnet only through Tailscale Serve; token auth stays on; WhatsApp DM and group policies are allowlists, never `open`; plugins are added by exact name, never by wildcard or auto-install.

## Architecture

- `lima/claw.yaml`, `provision/`: VM definition and idempotent guest provisioning (root); `provision/bot.sh` names the bot account.
- `host/`: `claw.sh` wrapper (`deploy`, `sebastian -- <cmd>`, `CLAW_INSTANCE`), `install.sh`, `pull-backups.sh` (streams the bot's nights through `sudo -u`) and its launchd plist.
- `migrate/`: `export.sh` (old VM), `import.sh` (guest, as the bot), the binary-path and home-path rewrites, the free-text scan, and `rehome.sh` (the in-place move to the bot account).
- `ops/`: listener guard (with its replay fixture), nightly backup, `backup-health.mjs`, shared dotenv-token parser.
- `tests/`: isolation, firewall, stack (as admin) and acceptance (as the bot) checks.
- `cmd/`, `internal/`: legacy Tart tooling (the `vmclaw` Go CLI), kept for rollback until Task 14 of `docs/superpowers/plans/2026-09-30-linux-vm-migration.md` (about 2026-10-15); its docs are in `docs/legacy-tart/`.

## Rollback

- Of the move to the bot account: `migrate/rehome.sh rollback`, until 14 days after `rehome.sh retire` (README "Rollback").
- To the Tart VM: README "Rollback", until Task 14 (about 2026-10-15).
````

- [ ] **Step 3: Update the comment in `lima/claw.yaml`**

Replace lines 15-19 with (comments only; the live instance does not re-read this file):

```yaml
user:
  name: admin
  # admin is Lima's login and maintenance user; its home keeps the old macOS guest's path. Since 2026-10-02 the bot and
  # its state live in the unprivileged account sebastian (/home/sebastian), which provisioning creates.
  home: /Users/admin
```

- [ ] **Step 4: Record the facts this work relies on in `docs/verification.md`**

Insert after the first table (after the `wacli auth status` row, before `## Notes`):

```markdown

## Bot account facts (2026-10-02)

| Fact | Result | Consequence |
|---|---|---|
| Guest accounts | `admin` is uid 501, gid 1000, groups `admin` and `systemd-journal`, with passwordless sudo from Lima's cloud-init; home `/Users/admin` | the bot gets an account of its own, without sudo (`sebastian`, 2000) |
| Bot units | `openclaw-gateway.service` is a systemd user unit with `NoNewPrivileges=no`; the listener guard and the nightly backup are user units too; linger is on for admin | run as admin, the agent could become root; the bot's units move to `sebastian`, whose linger provisioning enables |
| Tailscale | `tailscale debug prefs` shows `OperatorUser` null; with `gateway.tailscale.mode=serve` the gateway refuses to start when its Serve claim fails ("serve failed: Logged out") | provisioning sets `--operator=sebastian` once Tailscale is up; `import.sh final` and `rehome.sh prepare` check it |
| Absolute paths in the live `openclaw.json` | the exec secret-provider command (`/Users/admin/.openclaw/bin/op-nosym`, 6 times), the providers' `trustedDirs` (`/Users/admin/.openclaw/bin`, 6), the workspace (`/Users/admin/.openclaw/workspace`, 2) and the vault (`/Users/admin/brain/vault`, 1) | `migrate/homepaths.mjs` rewrites them; `migrate/scan-refs.mjs --old-home` fails on any left |
| Automations store | `~/.openclaw/cron/jobs.json`, which `doctor` normalizes | rewritten before doctor runs, scanned again after it |
| State relocation | OpenClaw documents `OPENCLAW_STATE_DIR` relocation; `openclaw memory status` reports `workspaceDir` and `dbPath` as absolute paths; `openclaw memory search` needs `--agent main` (several agents) | acceptance checks the memory paths; the memory-search MANUAL line names `--agent main` |
| `openclaw doctor --non-interactive` | writes | run only with the gateway stopped; the doctor comparison is done on a drill |
```

- [ ] **Step 5: Check the docs**

Run:

```bash
make lint
grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' README.md CLAUDE.md lima/claw.yaml docs/verification.md
for c in 'rehome.sh prepare' 'rehome.sh switch final' 'rehome.sh verify final' 'rehome.sh retire' 'rehome.sh rollback' 'claw.sh sebastian --' 'claw.sh deploy' 'CLAW_INSTANCE' 'import.sh drill' 'restic restore latest' 'mkdir -m 700 -p <host-dir>/rollback-state' 'launchctl print' 'openclaw-listener-guard.service'; do grep -qF -- "$c" README.md || echo "README lacks: $c"; done
```

Expected: shellcheck silent; the address grep lists only `127.0.0.1`, `100.64.0.0` and other addresses already present before this task (no LAN, tailnet or public address); the loop prints nothing.

- [ ] **Step 6: Commit**

```bash
git add README.md CLAUDE.md lima/claw.yaml docs/verification.md
git commit -m "docs: two-account runbook; rehearse, rebuild, restic restore and rollback guard rails" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 7: Final review gate (before any live run)**

Request the whole-range review of `8f21db3..HEAD` (superpowers:requesting-code-review), with the spec, this plan and the final-review findings as context. Also run every bash suite with `/bin/bash` 3.2 first on PATH:

```bash
for s in migrate/import.test.sh migrate/rehome.test.sh ops/backup/backup.test.sh host/install.test.sh host/claw.test.sh tests/acceptance.test.sh tests/stack-check.test.sh provision/vercmp.test.sh; do PATH="/bin:$PATH" /bin/bash "$s" | tail -1; done
make test
```

Expected: each suite's last line ends `0 failed`; `make test` passes. Fix every Critical and Important finding (one commit per fix, trailer included) before Task 10.

---

### Task 10: Rehearsal on `claw-drill` (operational, dev Mac; owner only to unlock the host keychain if asked)

**Files:**
- Modify: `docs/verification.md` (a new section `## Bot-account rehearsal (<date of the run>)` at the end)

**Interfaces:**
- Consumes: everything from Tasks 1-9, and the final review passed.
- Produces: a recorded PASS (or the list of deviations) that gates Task 11.

Nothing here touches the production guest or its gateway. The host is touched only to read the restic repository into a scratch directory. A drill never runs `import.sh final` or `switch final`: it would put a second gateway on the production WhatsApp credentials.

- [ ] **Step 1: Restore the newest night from restic on the host (proves README "Restore from restic")**

```bash
ssh -t -4 <host> 'export PATH=/opt/homebrew/bin:$PATH
  export RESTIC_REPOSITORY="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups/vm-claw-restic"
  export RESTIC_PASSWORD_COMMAND="security find-generic-password -s vm-claw-restic -w"
  restic snapshots --tag vm-claw | tail -4
  d=$(mktemp -d "$HOME/vm-claw-restore.XXXXXX"); chmod 700 "$d"
  restic restore latest --tag vm-claw --target "$d"
  night=$(find "$d" -type d -name "claw-nightly-*Z" | sort | tail -1); echo "NIGHT=$night"
  (cd "$night" && grep -v "^mode=" MANIFEST | shasum -a 256 --strict -c -)'
```

Expected: snapshots listed one night each; a restore summary; `NIGHT=<path>`; `openclaw-backup.tar.gz: OK` and `filestate.tar.gz: OK`. If the keychain is locked over ssh, the owner runs `security unlock-keychain ~/Library/Keychains/login.keychain-db` on the host first. Then copy that night to the dev Mac and remove the host's scratch copy:

```bash
mkdir -m 700 -p ~/drill-input
scp -rp <host>:"<the NIGHT path printed above>" ~/drill-input/
ssh -4 <host> 'rm -rf ~/vm-claw-restore.*'
```

- [ ] **Step 2: A fresh drill instance**

```bash
export CLAW_INSTANCE=claw-drill
host/claw.sh destroy 2>/dev/null || true
host/claw.sh create --memory 8 && host/claw.sh start && host/claw.sh provision 2>&1 | tail -4
host/claw.sh shell -- bash /opt/vm-claw/tests/stack-check.sh
```

Expected: `provision: changed=N ok=M` without `FAILED`; `skip tailscale operator (Tailscale is NeedsLogin; …)` and `stack: OK`.

- [ ] **Step 3: Reproduce production the old way, as admin**

Production runs the bot as admin with linger and a nightly timer; provisioning no longer gives admin linger, and a drill import installs no nightly, so both are added by hand:

```bash
host/claw.sh shell -- sudo loginctl enable-linger admin
host/claw.sh shell -- mkdir -p -m 700 claw-import
limactl copy --backend=scp -r ~/drill-input/claw-nightly-<ts> claw-drill:claw-import/
host/claw.sh shell -- bash /opt/vm-claw/migrate/import.sh drill /Users/admin/claw-import/claw-nightly-<ts>
host/claw.sh shell -- bash -c 'install -d ~/ops/backup ~/ops/lib ~/.config/systemd/user && cp /opt/vm-claw/ops/backup/nightly-backup.sh /opt/vm-claw/ops/backup/backup-health.mjs ~/ops/backup/ && cp /opt/vm-claw/ops/lib/dotenv-token.sh ~/ops/lib/ && cp /opt/vm-claw/ops/backup/openclaw-nightly-backup.service /opt/vm-claw/ops/backup/openclaw-nightly-backup.timer ~/.config/systemd/user/ && systemctl --user daemon-reload && systemctl --user enable --now openclaw-nightly-backup.timer'
host/claw.sh shell -- systemctl --user is-active openclaw-gateway.service openclaw-listener-guard.timer openclaw-nightly-backup.timer
```

Expected: `import: done (drill). Now run tests/acceptance.sh rehearsal <lan-ip>` (same home: no rewrite line), then `active` three times.

- [ ] **Step 4: Baseline as admin (gateway stopped: doctor writes)**

```bash
host/claw.sh shell -- bash -c 'systemctl --user stop openclaw-listener-guard.timer openclaw-gateway.service; openclaw doctor --non-interactive --allow-exec > ~/doctor-before.txt 2>&1; systemctl --user start openclaw-gateway.service openclaw-listener-guard.timer'
host/claw.sh shell -- bash -c 'openclaw sessions --all-agents --json | jq ".sessions | length"; jq ".jobs | length" ~/.openclaw/cron/jobs.json'
```

Record the two counts (sessions, automations).

- [ ] **Step 5: The switch, in drill mode**

```bash
host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh prepare
host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh switch drill
host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh verify rehearsal <lan-router-ip of the dev Mac's network>
```

Expected: `prepare: OK …`; then `rehome: admin's gateway, guard and nightly timer are stopped and disabled`, `rehome: admin's gateway logs moved to /tmp/openclaw.pre-rehome-<ts>`, `import: the archive comes from /Users/admin; its paths move to /home/sebastian`, `homepaths: N file(s) rewritten from /Users/admin to /home/sebastian`, `scan-refs: 0 file(s) still name /Users/admin` (twice), `import: done (drill)…`, `switch: done (drill, claw-nightly-<ts>)…`; then every acceptance item `PASS`, the two `MANUAL` lines, `acceptance (rehearsal): automated items PASS` and `verify: PASS…`. If the leftover scan names files, stop: record the list. Fixing them is a separate, owner-approved change on production (make the reference home-relative at its source) or a `homepaths.mjs` extension for a structured file, followed by a fresh rehearsal from Step 1.

- [ ] **Step 6: Hand checks as the bot**

```bash
host/claw.sh sebastian -- id
host/claw.sh sebastian -- sudo -n true; echo "rc=$?"
host/claw.sh sebastian -- /usr/sbin/nft list ruleset; echo "rc=$?"
host/claw.sh shell -- bash -c 'ps -eo user:12=,args= | grep -E "openclaw|guard\.mjs|nightly-backup|wacli" | grep -v grep'
host/claw.sh shell -- sudo stat -c '%U %a' /tmp/openclaw
host/claw.sh sebastian -- journalctl --user -u openclaw-gateway.service -n 5 --no-pager
host/claw.sh sebastian -- openclaw memory status --agent main
host/claw.sh sebastian -- openclaw memory search <a word from a recent note> --agent main
host/claw.sh sebastian -- bash -c 'openclaw sessions --all-agents --json | jq ".sessions | length"; openclaw sessions --all-agents --json | grep -c /Users/admin || true'
host/claw.sh sebastian -- bash -c 'jq ".jobs | length" .openclaw/cron/jobs.json; grep -c /Users/admin .openclaw/openclaw.json .openclaw/cron/jobs.json || true'
host/claw.sh sebastian -- openclaw channels status
host/claw.sh sebastian -- wacli doctor --read-only --json
```

Expected, in order: `uid=2000(sebastian) gid=2000(sebastian) groups=2000(sebastian)`; `sudo: a password is required` and `rc=1`; `Operation not permitted` and `rc=1`; every listed process owned by `sebastian`; `sebastian 7…`; recent gateway lines (the per-user journal works); memory paths under `/home/sebastian`; search results; the session count equal to Step 4's (and the count of `/Users/admin` in the session list recorded, whatever it is); the automation count equal to Step 4's and `:0` for both files; WhatsApp not linked (stripped) and no iMessage; the wacli store opens with its message count.

- [ ] **Step 7: Doctor after the switch, against the baseline (the bot's gateway stopped)**

```bash
host/claw.sh sebastian -- bash -c 'systemctl --user stop openclaw-listener-guard.timer openclaw-gateway.service; openclaw doctor --non-interactive --allow-exec > ~/doctor-after.txt 2>&1; systemctl --user start openclaw-gateway.service openclaw-listener-guard.timer'
host/claw.sh shell -- bash -c 'diff <(grep -iE "warn|error|fail" ~/doctor-before.txt | sed "s#/Users/admin#~#g") <(sudo cat /home/sebastian/doctor-after.txt | grep -iE "warn|error|fail" | sed "s#/home/sebastian#~#g")'
```

Expected: no line only on the right (no new warning). Record the diff, empty or not.

- [ ] **Step 8: Rollback before retire, then the switch again and retire**

```bash
host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh rollback
host/claw.sh shell -- systemctl --user is-active openclaw-gateway.service
host/claw.sh sebastian -- systemctl --user is-active openclaw-gateway.service
host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh switch drill
host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh verify rehearsal <lan-router-ip of the dev Mac's network>
host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh retire
host/claw.sh shell -- bash -c 'sudo stat -c "%U %a" /var/lib/claw-retired-admin-*; ls -A ~; loginctl show-user admin -p Linger'
```

Expected: `rollback: done; admin's gateway is active…`; `active` (admin) and `inactive` (bot); the switch and verify pass again; `retire: admin's copy is in /var/lib/claw-retired-admin-<date> (root only); delete it after <date + 14 days>`; `root 700`; admin's home lists none of `.openclaw brain .wacli ops backups claw-import`; `Linger=no`.

- [ ] **Step 9: Rollback after retire, then the final switch**

```bash
host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh rollback
host/claw.sh shell -- systemctl --user is-active openclaw-gateway.service
host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh switch drill
host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh verify rehearsal <lan-router-ip of the dev Mac's network>
host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh retire
```

Expected: `rehome: admin's copy is back from /var/lib/claw-retired-admin-<date>`, `rollback: done…`, `active`; then switch, verify and retire pass as in Step 8.

- [ ] **Step 10: Reboot once; the bot's units must start without a login**

```bash
host/claw.sh stop && host/claw.sh start
host/claw.sh sebastian -- systemctl --user is-active openclaw-gateway.service openclaw-listener-guard.timer
host/claw.sh sebastian -- systemctl --user show openclaw-gateway.service -p ActiveEnterTimestamp
host/claw.sh shell -- bash -c 'uptime -s; loginctl list-sessions --no-legend'
```

Expected: `active` twice; the gateway's start time after the boot time; only admin's own session listed (the one this command opened), none for `sebastian`.

- [ ] **Step 11: Record, clean up, commit**

Append to `docs/verification.md` a section `## Bot-account rehearsal (<date of the run>)`: a table with one row per step (1-10) and its observed result, the counts from Steps 4 and 6, the doctor diff from Step 7, and any deviation with what was done about it. No identifiers: no host names, addresses, job ids or account names beyond `admin` and `sebastian`. Then:

```bash
host/claw.sh destroy; unset CLAW_INSTANCE
rm -rf ~/drill-input
git add docs/verification.md
git commit -m "docs: bot-account rehearsal results" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Gate: Task 11 runs only when every step passed, or each deviation was fixed and the rehearsal run again.

---

### Task 11: The production switch (operational; the owner is present for Steps 4-6)

**Files:**
- Modify: `docs/verification.md` (a new section `## Move to the bot account (<date>)`)

**Interfaces:**
- Consumes: Task 10's recorded PASS; the README "Move the bot to its own account" sequence.
- Produces: production running as `sebastian`, admin's copy retired, the record.

Timing: start after the 09:00 backup check and after the host's 06:15 pull, and finish well before 03:30 UTC. From Step 1 on, the host's pull agent runs the new `host/pull-backups.sh`, which reads the bot's backups; the bot's first nightly is at 03:30 UTC, and the 06:15 pull picks it up.

- [ ] **Step 1: The code to the host (no downtime)**

On the dev Mac:

```bash
git bundle create ~/vm-claw.bundle feat/linux-vm
scp ~/vm-claw.bundle <host>:
ssh -4 <host> 'cd ~/s/vm-claw-linux && git fetch ~/vm-claw.bundle feat/linux-vm && git merge --ff-only FETCH_HEAD && git log -1 --oneline && rm ~/vm-claw.bundle'
rm ~/vm-claw.bundle
```

Expected: the branch head commit printed by the host.

- [ ] **Step 2: Provision production (no downtime; admin's gateway keeps running)**

```bash
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh provision 2>&1 | tail -30'
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh provision 2>&1 | tail -2'
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh shell -- bash /opt/vm-claw/tests/stack-check.sh'
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh shell -- systemctl --user is-active openclaw-gateway.service'
```

Expected: `deploy: <sha> at /opt/vm-claw in claw`; the first run shows `change  user sebastian …`, `change  sshd denies sebastian`, `change  linger sebastian`, `change  tailscale operator sebastian` and no `FAILED`; the second ends `changed=0`; stack-check prints `ok   tailscale operator sebastian` and `stack: OK`; admin's gateway is still `active`.

- [ ] **Step 3: Pre-flight**

```bash
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh prepare'
```

Expected: `prepare: OK (sebastian is ready; production untouched)`.

- [ ] **Step 4: The switch (owner present; the downtime starts)**

Note the time, then:

```bash
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh switch final'
```

Expected: the lines of Task 10 Step 5 with `final` in place of `drill`, ending `import: done (final). Now run tests/acceptance.sh final <lan-ip>` and `switch: done (final, claw-nightly-<ts>)…`. On any failure: `rehome.sh rollback` (owner decides), then record.

- [ ] **Step 5: Verify (owner present; the downtime ends when it passes)**

```bash
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh verify final <lan-router-ip>'
```

Expected: every automated item `PASS` (the guard replay shows `restart: stranded listener (2 events)` now that WhatsApp is linked), `acceptance (final): automated items PASS`, `verify: PASS…`. Note the time. The owner then confirms the `MANUAL` lines: one WhatsApp message answered; the face on the panel; a voice round-trip; `ssh admin@<name>` over Tailscale and `limactl shell claw` on the host; `host/claw.sh sebastian -- openclaw memory search <word> --agent main` returns results; the doctor comparison is Task 10 Step 7; the restore drill is Task 10. Two lines are confirmed later and recorded when seen: the first scheduled `ocsb-ingest` and announce runs succeed, and a vault commit is pushed (`host/claw.sh sebastian -- git -C brain/vault log -1 --format=%cI origin/HEAD` shows a time after the switch). An automated FAIL that cannot be fixed within about 15 minutes means `rehome.sh rollback`.

- [ ] **Step 6: Retire admin's copy (owner present)**

```bash
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh retire'
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh shell -- bash -c "sudo stat -c \"%U %a\" /var/lib/claw-retired-admin-*; ls -A ~; loginctl show-user admin -p Linger"'
```

Expected: `retire: … delete it after <date>`; `root 700`; no bot items in admin's home; `Linger=no`.

- [ ] **Step 7: The host's pull agent gets its instance**

```bash
ssh -t -4 <host> 'cd ~/s/vm-claw-linux && bash host/install.sh'
ssh -4 <host> 'grep -o "<key>CLAW_INSTANCE</key><string>[a-z0-9-]*</string>" ~/Library/LaunchAgents/local.vm-claw.pull-backups.plist'
```

Expected: `pull agent loaded`; `<key>CLAW_INSTANCE</key><string>claw</string>`.

- [ ] **Step 8: The next morning: the backup chain as the bot**

```bash
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh sebastian -- bash -c "ls -d ~/backups/claw-nightly-*; cat ~/backups/.host-pull-ok"; tail -5 ~/Library/Logs/vm-claw-pull-backups.log'
ssh -4 <host> 'export PATH=/opt/homebrew/bin:$PATH RESTIC_REPOSITORY="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups/vm-claw-restic" RESTIC_PASSWORD_COMMAND="security find-generic-password -s vm-claw-restic -w"; restic snapshots --tag vm-claw --latest 2'
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh shell -- bash -c "ps -eo user:12=,args= | grep -E \"openclaw|guard\\.mjs|nightly-backup|wacli\" | grep -v grep"'
```

Expected: one bot nightly from 03:30 UTC and a stamp from about 06:15; the log's last lines carry no `FAILED`; the newest snapshot's path ends in that night's name; every bot process is `sebastian`. The owner confirms no `BACKUP ALERT` arrived at 09:00.

- [ ] **Step 9: Record and commit**

Append `## Move to the bot account (<date>)` to `docs/verification.md`: a table with the downtime (start, end, minutes), each step's result, the MANUAL confirmations (with the two late ones filled in when seen, in a follow-up commit if needed), the retired copy's deletion date, and the next-morning backup chain. No identifiers.

```bash
git add docs/verification.md
git commit -m "docs: the move to the bot account on production" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Delete admin's retired copy (operational, 14 days after Task 11 Step 6; the owner approves)

**Files:**
- Modify: `docs/verification.md` (one row appended to the Task 11 table)

**Interfaces:**
- Consumes: the retired copy and its `RETIRED` file from Task 11.
- Produces: no bot state anywhere under admin; the rollback of the move is no longer possible (restore from backups instead).

- [ ] **Step 1: Check that it is time and nothing needs it**

```bash
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh shell -- sudo head -1 /var/lib/claw-retired-admin-<date>/RETIRED'
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh sebastian -- bash /opt/vm-claw/tests/acceptance.sh final <lan-router-ip>'
```

Expected: the deletion date is today or earlier; `acceptance (final): automated items PASS`. The owner confirms that no rollback is wanted; deleting cannot be undone.

- [ ] **Step 2: Delete**

```bash
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh shell -- sudo rm -rf /var/lib/claw-retired-admin-<date>'
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh sebastian -- rm -rf claw-import'
ssh -4 <host> 'cd ~/s/vm-claw-linux && host/claw.sh shell -- bash -c "rm -rf ~/vm-claw; ls -A ~; ls ~/.ssh; sudo ls /var/lib | grep claw-"'
```

`~/vm-claw` is the pre-2026-10-02 repo copy in admin's home (the repo now lives at `/opt/vm-claw`). Expected: admin's home lists only its shell dotfiles and `.ssh`; `.ssh` holds `authorized_keys` only; under `/var/lib` only `claw-rehome` is left.

- [ ] **Step 3: Record and commit**

Append a row `Retired copy deleted (<date>)` with the result of Step 2 to the Task 11 table in `docs/verification.md`.

```bash
git add docs/verification.md
git commit -m "docs: admin's retired bot copy deleted" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9b (added 2026-10-05): OpenClaw state-path migration

**Why.** The Task 10 rehearsal found that OpenClaw 2026.9.7 keys SQLite state by absolute path. See the spec addendum of 2026-10-05.

**What.**
- `migrate/state-paths.py` holds the version-pinned rewrite and recompute.
- It has a fail-closed post-check and a `--check` mode for after the first start.
- It has unit tests on fixture databases.

**Wiring.**
- `import.sh` runs it on a cross-home import, right after the restored state is moved in and before the first `openclaw` command.
- The import also does the file rewrites, moves the config backups aside, and extends the scan roots.
- `rehome.sh switch` records admin's automation count before the stop. `rehome.sh verify` runs the post-start checks.

**Gate.** Task review (opus), then the rehearsal again from a fresh drill.

**Source of the recipe.** The controller's research notes (not in the repo).
