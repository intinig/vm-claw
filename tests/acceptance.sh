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
  local nft first
  run sudo -n true
  case "$RC" in 126|127) OUT=""; WHY="sudo not found or not executable: the root check cannot run"; return 1 ;; esac
  [ "$RC" -ne 0 ] || { OUT=""; WHY="sudo -n true succeeded: $(id -un) can become root"; return 1; }
  run sudo -n -l
  case "$RC" in 126|127) OUT=""; WHY="sudo not found or not executable: the root check cannot run"; return 1 ;; esac
  [ "$RC" -ne 0 ] || { OUT=""; ERR=""; WHY="sudo -n -l lists commands $(id -un) may run without a password"; return 1; }
  nft=$(PATH="$PATH:/usr/sbin:/sbin"; command -v nft) \
    || { WHY="nft not found (provisioning installs nftables): cannot show that the firewall is out of reach"; return 1; }
  run "$nft" list table inet claw
  # Never show the ruleset (its addresses) on a FAIL.
  if [ "$RC" -eq 0 ]; then OUT=""; ERR=""; WHY="$(id -un) can read the inet claw table, so it holds CAP_NET_ADMIN and could change it"; return 1; fi
  # Only a permission denial proves the capability is missing: a missing table or a broken nft proves nothing.
  if grep -qi 'operation not permitted' <<<"$OUT$ERR"; then return 0; fi
  first=$(printf '%s\n%s\n' "$ERR" "$OUT" | sed '/^[[:space:]]*$/d' | head -1 | cut -c1-120)
  OUT=""; ERR=""
  WHY="nft failed for another reason, so the denial is not proven: $first"; return 1
}

# Every bot process runs as this account: the gateway's main process, and nothing that looks like the bot under any
# other uid (an admin gateway left running would be two gateways on one WhatsApp identity). The scan must see the
# gateway's own row, or it proves nothing (a hidden /proc shows nothing at all). Its FAIL names only the culprit:
# other processes' argv can carry secrets and is never printed.
check_bot_owner() {
  local pid owner me culprit="" rpid uid args sargs seen=0 matched=0 gwargs="" unit units
  me=$(id -u)
  produce systemctl --user show openclaw-gateway.service -p MainPID --value || return 1
  pid=$(printf '%s' "$OUT" | tr -d '[:space:]')
  [[ $pid =~ ^[1-9][0-9]*$ ]] || { WHY="the gateway has no main process (MainPID '$pid')"; return 1; }
  produce ps -o uid= -p "$pid" || return 1
  owner=$(printf '%s' "$OUT" | tr -d '[:space:]')
  [ "$owner" = "$me" ] || { WHY="the gateway (pid $pid) runs as uid ${owner:-unknown}, not $me"; return 1; }
  # The nightly timer exists in final mode only: import.sh installs the backup units there, a drill has none.
  units="openclaw-listener-guard.timer"
  if [ "$mode" = final ]; then units="$units openclaw-nightly-backup.timer"; fi
  for unit in $units; do
    run systemctl --user is-enabled "$unit"
    [ "$RC" -eq 0 ] || { WHY="$unit is not enabled (exit $RC)"; return 1; }
  done
  run ps -eo pid=,uid=,args= ww
  # A failed ps may still have printed part of a table: none of it is shown.
  [ "$RC" -eq 0 ] || { OUT=""; ERR=""; WHY="cannot list processes (ps exit $RC)"; return 1; }
  while read -r rpid uid args; do
    if [ -z "$uid" ]; then continue; fi
    if [ "$rpid" = "$pid" ]; then
      seen=1
      if [[ $args =~ $BOT_PROC_RE ]]; then matched=1; else gwargs=$(scrub "$args"); fi
    fi
    if [ "$uid" = "$me" ] || [ -n "$culprit" ]; then continue; fi
    # Scrub the whole argv first, then cut: a token cut at the boundary would no longer match.
    if [[ $args =~ $BOT_PROC_RE ]]; then sargs=$(scrub "$args"); culprit="pid $rpid uid $uid: ${sargs:0:80}"; fi
  done <<<"$OUT"
  OUT=""; ERR=""
  [ "$seen" -eq 1 ] || { WHY="cannot see the gateway's own process: is /proc hidden?"; return 1; }
  # The scan below only means something if its pattern recognises the gateway itself.
  [ "$matched" -eq 1 ] || { WHY="BOT_PROC_RE does not match the gateway's own process, so a stray gateway under another user could go unseen: fix the pattern in tests/acceptance.sh (gateway argv starts: ${gwargs:0:60})"; return 1; }
  [ -z "$culprit" ] || { WHY="a bot process of another account: $culprit"$'\n'"(your own tail -f of /tmp/openclaw/... or a concurrent claw.sh sebastian -- openclaw ... can also trip this)"; return 1; }
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
  local st mark ran=0
  st=$(mktemp "${TMPDIR:-/tmp}/acceptance-guard.XXXXXX") || { WHY="cannot create a temp file"; return 1; }
  mark="$st.restarted"
  # In final mode on a linked guest this is the one call that reaches a restart decision: the command is a stub.
  run env GUARD_LOG_DIR="$GUARD_FIXTURE" GUARD_STATE="$st" GUARD_RESTART="touch '$mark'" node "$HOME/ops/listener-guard/guard.mjs" --dry-run --now "$GUARD_REPLAY_AT"
  if [ -e "$mark" ]; then ran=1; fi
  rm -f "$st" "$mark"
  [ "$ran" = 0 ] || { WHY="the guard ran its restart command during a dry-run replay"; return 1; }
  [ "$RC" -eq 0 ] || { WHY="exit $RC"; return 1; }
  if [ "$mode" = final ]; then
    matches '^\[dry-run\] 2026-09-30T09:02:00\.000Z restart: stranded listener \(2 events\)$' "the replay of the stranded-listener log did not decide to restart"
  else
    if grep -Eq '^\[dry-run\] .* restart: ' <<<"$OUT"; then
      WHY="the drill reports WhatsApp linked: its credentials were not stripped (never run two gateways on one WhatsApp identity)"; return 1
    fi
    matches '^\[dry-run\] 2026-09-30T09:02:00\.000Z skip: WhatsApp not linked \(2 events\)$' "the replay did not reach 'skip: WhatsApp not linked' (2 events)"
  fi
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
  local dir f n=0
  # The value the unit actually runs with (systemd prints the environment as one space-separated line).
  run systemctl --user show openclaw-listener-guard.service -p Environment --value
  [ "$RC" -eq 0 ] || { OUT=""; WHY="cannot read the guard unit's environment (systemctl exit $RC)"; return 1; }
  dir=$(printf '%s\n' "$OUT" | tr ' ' '\n' | sed -n 's/^GUARD_LOG_DIR=//p' | tail -1)
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
  local p n=0 bad="" found abs path_re='[^[:space:]"=,()]*/\.openclaw[^[:space:]",()]*'
  local abs_re='(^|[[:space:]"=,(])/(Users|home)/[^[:space:]",()]*'
  produce openclaw memory status --agent main || return 1
  strip_ansi
  found=$(grep -oE -- "$path_re" <<<"$OUT" || true)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    n=$((n + 1))
    # shellcheck disable=SC2088  # a literal ~: OpenClaw may print a path relative to the home it runs in
    case "$p" in "$HOME"/.openclaw*|"~/.openclaw"*) ;; *) bad="$bad $p" ;; esac
  done <<<"$found"
  # Any other absolute home-directory path (another account's, or the old machine's) is as stray as a .openclaw one.
  abs=$(grep -oE -- "$abs_re" <<<"$OUT" | sed 's/^[^/]*//' || true)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    n=$((n + 1))
    case "$p" in "$HOME"|"$HOME"/*) ;; *) case " $bad " in *" $p "*) ;; *) bad="$bad $p" ;; esac ;; esac
  done <<<"$abs"
  [ "$n" -gt 0 ] || { WHY="memory status printed no path under a .openclaw directory"; return 1; }
  [ -z "$bad" ] || { WHY="memory paths outside $HOME:$bad"; return 1; }
}

# With no display OpenClaw launches its browser headless, and Cloudflare blocks HeadlessChrome (ops/browser-display).
# The status names where the headless setting came from; it answers without the browser running.
check_browser_display() {
  run systemctl --user is-active openclaw-xvfb.service
  [ "$RC" -eq 0 ] || { WHY="openclaw-xvfb.service is ${OUT:-unknown} (systemctl exit $RC)"; return 1; }
  produce openclaw browser status || return 1
  strip_ansi
  matches '^headless: false' "the managed browser would run headless: is DISPLAY set by the gateway's drop-in openclaw-gateway.service.d/browser-display.conf?"
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
item "managed browser has a display (headed, not the headless fallback)" check_browser_display
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
