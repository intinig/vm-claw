#!/bin/bash
# Run on the NEW (Linux) VM. Usage: import.sh rehearsal|final|drill <export-dir> [--force]
#   rehearsal  import a rehearsal export (must carry no WhatsApp credentials); cron stays off
#   final      import the final export (or a nightly backup: same layout); WhatsApp credentials carried over, cron stays on
#   drill      restore any archive (final, nightly, rehearsal) for a restore drill: strips both
#              WhatsApp credential sets and disables cron before anything starts
# Run it as the account that will own the state: the bot account (docs/superpowers/specs/2026-10-02-bot-user-sebastian-design.md).
# An archive made under another home (the in-place move from /Users/admin) has that home rewritten to $HOME in
# structured configuration (migrate/homepaths.mjs); any trace of it left in live configuration fails the import
# (migrate/scan-refs.mjs --old-home); and its authorized_keys is not installed.
# Exit 0 only if every gate passes.
# IMPORT_DRY=1 stops after validation (used by import.test.sh). IMPORT_HOME overrides $HOME for tests.
set -euo pipefail
usage() { echo "usage: $0 rehearsal|final|drill <export-dir> [--force]" >&2; exit 2; }
mode="${1:-}"; src="${2:-}"; force="${3:-}"
case "$mode" in rehearsal|final|drill) ;; *) usage ;; esac
[ -n "$src" ] || usage
case "$force" in ""|--force) ;; *) usage ;; esac
repo="$(cd "$(dirname "$0")/.." && pwd)"
H="${IMPORT_HOME:-$HOME}"
GATEWAY_UNIT=openclaw-gateway.service   # verified: what `openclaw gateway install` creates on Linux (docs/verification.md)
die() { echo "import: $*" >&2; exit 1; }
stage=""
sel=""
trap '[ -z "$stage" ] || rm -rf "$stage"; [ -z "$sel" ] || rm -f "$sel"' EXIT

# The MANIFEST is written on macOS (`shasum -a 256`); both tools read the same `hash  file` lines.
sha256_check() { if command -v sha256sum >/dev/null 2>&1; then sha256sum --strict -c -; else shasum -a 256 --strict -c -; fi; }

# --- validation: nothing is touched until all of it passes ----------------------------------
[ -d "$src" ] || die "export dir $src not found"
src="$(cd "$src" && pwd)"
[ -f "$src/MANIFEST" ] || die "no MANIFEST in $src"
got_mode=$(sed -n 's/^mode=//p' "$src/MANIFEST")
[ "$got_mode" = nightly ] && [ "$mode" = final ] && got_mode=final   # nightly and final share a layout
[ "$mode" = drill ] && got_mode=drill   # a drill may restore any archive; it strips credentials below
[ "$got_mode" = "$mode" ] || die "archive is a '$got_mode' export; refusing to import it as '$mode'"
# Both archives must be listed with a well-formed hash: the checker only skips a malformed line (with a
# warning, exit 0) unless --strict, so a line it cannot parse must not count as "listed".
for f in openclaw-backup.tar.gz filestate.tar.gz; do
  awk -v f="$f" '$2 == f && $1 ~ /^[0-9a-f]{64}$/ { found = 1 } END { exit !found }' "$src/MANIFEST" \
    || die "MANIFEST in $src does not list $f with a 64-hex sha256"
done
(cd "$src" && grep -v '^mode=' MANIFEST | sha256_check) >/dev/null || die "checksum mismatch or malformed MANIFEST line in $src"
backup_list=$(tar -tzf "$src/openclaw-backup.tar.gz") || die "cannot read $src/openclaw-backup.tar.gz"
files_list=$(tar -tzf "$src/filestate.tar.gz") || die "cannot read $src/filestate.tar.gz"
if [ "$mode" = rehearsal ]; then
  if grep -Eq '(^|/)credentials/whatsapp(\.backup[^/]*)?/' <<<"$backup_list" \
     || grep -Eq '(^|/)credentials/whatsapp(\.backup[^/]*)?/|(^|/)\.wacli/session\.db' <<<"$files_list"; then
    die "rehearsal import found WhatsApp credentials in the archive — two gateways must never share them"
  fi
fi
if [ -e "$H/.openclaw/openclaw.json" ]; then
  [ "$force" = --force ] || die "$H/.openclaw already has state; re-run with --force to move it aside"
fi
[ "${IMPORT_DRY:-0}" = 1 ] && { echo "import: validation OK ($mode)"; exit 0; }

# --- pre-flight for a real run (still nothing touched) ------------------------------------------
for c in openclaw node npm op systemctl; do command -v "$c" >/dev/null 2>&1 || die "$c not found on PATH"; done
# Restored as root, the state would be root's and the bot's units could not use it.
[ "$(id -u)" != 0 ] || die "run as the account that will own the state (the bot account), not as root"
# systemctl --user (the units, gateway install) needs this account's own user manager.
systemctl --user show-environment >/dev/null 2>&1 \
  || die "no systemd user manager for $(id -un): run through host/claw.sh sebastian -- ... (it sets XDG_RUNTIME_DIR), and the account needs linger"
[ -f "$repo/ops/listener-guard/guard.mjs" ] || die "ops/listener-guard/guard.mjs missing from the repo checkout"
[ -f "$repo/ops/lib/dotenv-token.sh" ] || die "ops/lib/dotenv-token.sh missing from the repo checkout"
# shellcheck source=ops/lib/dotenv-token.sh
. "$repo/ops/lib/dotenv-token.sh"
for f in migrate/homepaths.mjs migrate/scan-refs.mjs migrate/lib/home-roots.sh migrate/state-paths.py \
  ops/browser-display/openclaw-xvfb.service ops/browser-display/browser-display.conf; do
  [ -f "$repo/$f" ] || die "$f missing from the repo checkout"
done
# shellcheck source=migrate/lib/home-roots.sh
. "$repo/migrate/lib/home-roots.sh"
# The archive's home, read from the listing of the OpenClaw backup (<root>/payload/posix<home>/.openclaw/...), so
# that a bad home or a login on this account is refused before anything is stopped. An archive whose listing does
# not show it falls back to the restored layout below.
valid_home() { [[ $1 =~ ^(/[A-Za-z0-9._-]+)+$ ]] && ! [[ $1 == */../* || $1 == */.. ]]; }
refuse_ssh_login() { # [rm]: the bot account has no SSH login (spec 2026-10-02 §1); a dangling symlink counts
  local f first=""
  for f in "$H/.ssh/authorized_keys" "$H/.ssh/authorized_keys2"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      if [ -z "$first" ]; then first=$(basename "$f"); fi
      if [ "${1:-}" = rm ]; then rm -rf "$f"; fi   # only after our own extraction, never a file that was here before; a link goes, not its target
    fi
  done
  [ -z "$first" ] || die "$H/.ssh holds $first, but the account importing another home's state is the bot account, which must have no SSH login; remove the file (provisioning asserts it is absent)"
}
# Another home's file state may hold no symlink that is .ssh or lies under it: the steps after the extraction would
# act on the link's target. The verbose listing is never parsed for names: it is paired line by line with the plain
# one (files_list) and only its first character, the entry type, is read; listings that do not pair up are refused.
# Names only are printed.
ssh_links_checked=0
refuse_ssh_links() {
  local vlist n v raw bad="" n_plain n_verbose
  ssh_links_checked=1
  vlist=$(tar -tvzf "$src/filestate.tar.gz") || die "cannot list $src/filestate.tar.gz"
  n_plain=$(grep -c '' <<<"$files_list"); n_verbose=$(grep -c '' <<<"$vlist")
  [ "$n_plain" -eq "$n_verbose" ] \
    || die "the plain and verbose listings of filestate.tar.gz differ ($n_plain and $n_verbose lines), so its .ssh members cannot be checked for symlinks"
  while IFS= read -r n <&3 && IFS= read -r v <&4; do
    case "$v" in l*) ;; *) continue ;; esac
    raw="$n"
    while :; do case "$n" in ./*) n="${n#./}" ;; /*) n="${n#/}" ;; *) break ;; esac; done
    while :; do case "$n" in */) n="${n%/}" ;; *) break ;; esac; done
    case "$n" in .ssh|.ssh/*) bad="${bad:+$bad }$raw" ;; esac
  done 3<<<"$files_list" 4<<<"$vlist"
  [ -z "$bad" ] || die "filestate.tar.gz has a symlink at or under .ssh, which the bot account must not take from another home: $bad"
}
listed_homes=""
while IFS= read -r m; do
  case "$m" in *payload/posix/*) ;; *) continue ;; esac
  rest="/${m#*payload/posix/}"
  case "$rest" in */.openclaw/*) h="${rest%%/.openclaw/*}" ;; */.openclaw) h="${rest%/.openclaw}" ;; *) continue ;; esac
  case $'\n'"$listed_homes"$'\n' in *$'\n'"$h"$'\n'*) ;; *) listed_homes="${listed_homes:+$listed_homes$'\n'}$h" ;; esac
done <<<"$backup_list"
# This account's own ~/.ssh is never removed or written through, on any import: a symlink (or a non-directory) here
# is refused before anything is stopped, and anything the guard after the extraction finds was made by tar.
if [ -L "$H/.ssh" ] || { [ -e "$H/.ssh" ] && [ ! -d "$H/.ssh" ]; }; then die "$H/.ssh is a symlink or not a directory; the import never writes, merges or chmods through it: make it a real directory and re-run (nothing was changed)"; fi
arch_home=""
if [ -n "$listed_homes" ]; then
  n_homes=$(grep -c '' <<<"$listed_homes")
  [ "$n_homes" -eq 1 ] || die "restore layout unexpected: the backup lists $n_homes different homes under payload/posix (see docs/verification.md)"
  valid_home "$listed_homes" || die "the archive's home '$listed_homes' is not a plain absolute path"
  arch_home="$listed_homes"
  if [ "$arch_home" != "$H" ]; then refuse_ssh_login; refuse_ssh_links; fi
fi
# A cross-home import moves OpenClaw's path-keyed SQLite state with python3 (migrate/state-paths.py) mid-downtime: it
# must be here before this import stops anything. A listing that shows no home may be cross-home too. (In a rehome.sh
# switch, admin's units are already off by now: the message says what this import did, and rehome.sh says the rest.)
if [ "$arch_home" != "$H" ] && ! command -v python3 >/dev/null 2>&1; then
  die "python3 not found on PATH: a cross-home import needs it for migrate/state-paths.py (provisioning installs it); this import has stopped and changed nothing"
fi
if [ "$mode" = final ] && [ ! -f "$repo/ops/backup/nightly-backup.sh" ]; then
  die "ops/backup/ missing from the repo checkout (final mode installs the nightly backup timer)"
fi
# The bootstrap token's member is ~/.openclaw/.env in an archive made on Linux (the nightly backup), or the
# macOS gateway env file in an export from the old VM. Either is read straight from the archive (nothing
# is written yet). The Linux dotenv wins if an archive carries both: it is the source of truth there, and
# the only one that is never evaluated.
dotenv_member=$(grep -E '^(\./)?\.openclaw/\.env$' <<<"$files_list" | head -1 || true)
macos_member=$(grep -E '^(\./)?\.openclaw/service-env/ai\.openclaw\.gateway\.env$' <<<"$files_list" | head -1 || true)
if [ -n "$dotenv_member" ]; then env_kind=dotenv; env_member="$dotenv_member"; envsrc="$H/.openclaw/.env"
elif [ -n "$macos_member" ]; then env_kind=macos; env_member="$macos_member"; envsrc="$H/.openclaw/service-env/ai.openclaw.gateway.env"
else die "filestate.tar.gz carries neither .openclaw/.env nor a service-env file, so the bootstrap token cannot be carried over"; fi
if [ "$env_kind" = dotenv ]; then
  # A dotenv is data, never code: dotenv_token (ops/lib, shared with the nightly backup) parses the one
  # OP_SERVICE_ACCOUNT_TOKEN= line and refuses anything a loader could read differently.
  tok=$(tar -xzOf "$src/filestate.tar.gz" "$env_member" | dotenv_token -) \
    || die "the bootstrap token in $env_member of filestate.tar.gz is unusable (see above)"
else
  # The old gateway env file is a macOS launchd artefact (`export KEY=value`, macOS PATH and label): only its
  # bootstrap token is carried over. It is run in a subshell that starts without any inherited token, so any
  # quoting OpenClaw used is honoured and an inherited variable cannot stand in for a missing one. (eval,
  # because bash 3.2 cannot source a process substitution and the tests run under it.) The value then goes
  # through the same checks as a dotenv token.
  tok=$(unset OP_SERVICE_ACCOUNT_TOKEN; set +u; eval "$(tar -xzOf "$src/filestate.tar.gz" "$env_member")" >/dev/null 2>&1; printf '%s' "${OP_SERVICE_ACCOUNT_TOKEN:-}")
  [ -n "$tok" ] || die "bootstrap token missing from the carried env file"
  # Checked as the file set it, before it is wrapped into a dotenv line and parsed again: a value with a
  # newline or with literal quote characters would come out of that round trip changed, not refused.
  [[ "$tok" =~ ^[A-Za-z0-9_.=+/:@%-]+$ ]] || die "bootstrap token has characters a dotenv file cannot carry unquoted"
  tok=$(printf 'OP_SERVICE_ACCOUNT_TOKEN=%s\n' "$tok" | dotenv_token -) \
    || die "the bootstrap token in $env_member of filestate.tar.gz is unusable (see above)"
fi
# Kept in a plain shell variable, not the environment: npm ci below runs third-party lifecycle scripts.
unset OP_SERVICE_ACCOUNT_TOKEN
case "$mode" in rehearsal|drill) no_wa=1 ;; *) no_wa=0 ;; esac

# The migrated config may publish the gateway on the tailnet (gateway.tailscale.mode serve|funnel). OpenClaw
# holds that as a foreground claim and the gateway does not start without a logged-in Tailscale ("Logged
# out"). Read the mode from the archive (nothing is restored yet).
ts_mode=""
config_member=$(grep -E '(^|/)\.openclaw/openclaw\.json$' <<<"$backup_list" | head -1 || true)
if [ -n "$config_member" ]; then
  ts_mode=$(tar -xzOf "$src/openclaw-backup.tar.gz" "$config_member" \
    | node -e 'const c = JSON.parse(require("fs").readFileSync(0, "utf8")); process.stdout.write(String(c?.gateway?.tailscale?.mode ?? ""))') \
    || die "cannot read gateway.tailscale.mode from the config in $src/openclaw-backup.tar.gz"
fi
if [ "$mode" = final ]; then
  case "$ts_mode" in
    serve|funnel)
      ts_state=$(tailscale status --json 2>/dev/null | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0, "utf8")).BackendState ?? ""))' 2>/dev/null || true)
      [ "$ts_state" = Running ] \
        || die "gateway.tailscale.mode=$ts_mode needs a logged-in Tailscale (run: sudo tailscale up ...) before a final import (BackendState is '${ts_state:-unknown}')"
      # The gateway claims Serve itself; without root that takes the operator setting (provisioning sets it).
      ts_prefs=$(tailscale debug prefs 2>/dev/null) || die "gateway.tailscale.mode=$ts_mode: 'tailscale debug prefs' failed, so Tailscale's operator cannot be checked"
      ts_op=$(printf '%s' "$ts_prefs" | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0, "utf8")).OperatorUser ?? ""))' 2>/dev/null) \
        || die "gateway.tailscale.mode=$ts_mode: cannot read OperatorUser from 'tailscale debug prefs'"
      [ "$ts_op" = "$(id -un)" ] \
        || die "gateway.tailscale.mode=$ts_mode: Tailscale's operator must be $(id -un), not '${ts_op:-none}' (host/claw.sh provision sets it once Tailscale is up)" ;;
  esac
fi

# --- restore: nothing live is touched until the commit point -------------------------------
# Nothing may start a gateway on these credentials mid-import, and a half-finished import must not come
# back armed after a reboot (the guest lingers): disable, not just stop, and prove it. The guard goes
# first: a guard run already in flight can restart the gateway, so the gateway is stopped last.
guard_units=(openclaw-listener-guard.timer openclaw-listener-guard.service)
stop_order=("${guard_units[@]}" "$GATEWAY_UNIT")
for u in "${stop_order[@]}"; do systemctl --user disable --now "$u" 2>/dev/null || true; done
for u in "${stop_order[@]}"; do
  # Exactly inactive or failed: "activating" (a restart still starting) must not pass, and neither may
  # anything unexpected. `is-active` prints the state and exits non-zero for every state but active.
  state=$(systemctl --user is-active "$u" 2>/dev/null || true)
  case "$state" in inactive|failed) ;; *) die "$u is '${state:-unknown}' after disable --now; refusing to replace the state under it" ;; esac
done
# Stage on the home filesystem, not /tmp: /tmp is a RAM-backed tmpfs on Debian 13, too small for a
# multi-GB restore. Same filesystem also lets the restored tree be renamed into place, not copied.
stage=$(mktemp -d "$H/.import-stage.XXXXXX")
openclaw backup restore "$src/openclaw-backup.tar.gz" --target "$stage/r"
# Layout recorded in docs/verification.md: <target>/<archive root>/payload/posix<archive home>/.openclaw. The archive's
# home is the account that made it: this home on a rebuild, another one (/Users/admin) when the state moves to the
# bot account in place.
restored_dirs=()
while IFS= read -r d; do restored_dirs+=("$d"); done < <(find "$stage/r" -mindepth 4 -type d -name .openclaw -path "$stage/r/*/payload/posix/*" -prune -print)
[ "${#restored_dirs[@]}" -eq 1 ] \
  || die "restore layout unexpected: want exactly one $stage/r/<archive root>/payload/posix<home>/.openclaw, found ${#restored_dirs[@]} (see docs/verification.md)"
restored="${restored_dirs[0]}"
found_home="${restored%/.openclaw}"
found_home="/${found_home#"$stage/r"/*/payload/posix/}"
valid_home "$found_home" || die "the archive's home '$found_home' is not a plain absolute path"
[ -z "$arch_home" ] || [ "$arch_home" = "$found_home" ] \
  || die "the archive's home from its listing ($arch_home) differs from the restored layout ($found_home)"
arch_home="$found_home"
if [ "$arch_home" = "$H" ]; then rehome=0; else rehome=1; echo "import: the archive comes from $arch_home; its paths move to $H"; fi
# A listing that showed no home could not tell a cross-home import at validation: its .ssh symlinks are checked here,
# still before anything lands.
if [ "$rehome" = 1 ]; then refuse_ssh_login; if [ "$ssh_links_checked" = 0 ]; then refuse_ssh_links; fi; fi
# Rehearsal and drill strip every WhatsApp credential file in the stage, so none is ever live under $H.
if [ "$no_wa" = 1 ]; then
  rm -rf "$restored/credentials/"whatsapp*
  left=$(find "$restored/credentials" -mindepth 1 -maxdepth 1 -name 'whatsapp*' 2>/dev/null || true)
  [ -z "$left" ] || die "WhatsApp credentials survived the strip in the stage; refusing to go on"
fi

# --- commit point ---------------------------------------------------------------------------
if [ -e "$H/.openclaw" ]; then
  aside="$H/.openclaw.pre-import-$(date -u +%Y%m%dT%H%M%SZ)"
  # mv into an existing directory would nest the old state inside it instead of moving it aside.
  [ ! -e "$aside" ] || die "$aside already exists; refusing to nest the old state in it"
  mv "$H/.openclaw" "$aside"
  echo "import: existing state moved to $aside"
fi
[ ! -e "$H/.openclaw" ] || die "$H/.openclaw still exists; refusing to move the restored state into it"
mv "$restored" "$H/.openclaw"
rm -rf "$stage"; stage=""
chmod 700 "$H/.openclaw"
# OpenClaw 2026.9.7 keys parts of its SQLite state by absolute path (the cron store, workspace identity, memory and
# plugin state, Workshop targets, the exec-approvals socket, Codex's threads). From another home they move to this one
# now, before any openclaw command opens the state: a config write already records the new home, and doctor --fix
# stales the Workshop proposals. Pinned to OpenClaw 2026.9.7; it refuses state already touched and fails closed
# (spec 2026-10-02, addendum 2026-10-05). It runs before the cron-off below on purpose. Exit 3: a COMMIT failed after an
# earlier database committed, so this state is half moved and only a fresh copy of the archive is good again.
if [ "$rehome" = 1 ]; then
  sp_rc=0
  python3 "$repo/migrate/state-paths.py" migrate --old "$arch_home" --new "$H" --state "$H/.openclaw" || sp_rc=$?
  case "$sp_rc" in
    0) ;;
    3) die "the OpenClaw state-path migration committed part of its work and then failed (see above): this state is inconsistent; nothing after the migration ran on it: rehome.sh rollback, then switch again" ;;
    *) die "the OpenClaw state-path migration failed closed (see above); nothing after it ran on the state" ;;
  esac
fi
# The archive's openclaw.json backups are untouched copies of its config: the old home's paths and settings. OpenClaw
# restores .last-good automatically, reads .bak as the baseline of a "suspicious" config and rotates .bak* on a config
# write, so none may stay where it looks. Moved aside, never deleted, into a dir that is no scan root (classification §7
# N3): right after the state-path migration, before the first config write (the drill's cron off below), so OpenClaw's
# own rotation never runs on them. OpenClaw writes fresh ones.
config_backups_aside() {
  local d="$H/.openclaw/pre-rehome-config-backups${1:+/$1}" f n=0
  for f in "$H/.openclaw/openclaw.json.last-good" "$H/.openclaw/"openclaw.json.bak* "$H/.openclaw/"openclaw.json.pre-* \
           "$H/.openclaw/"openclaw.json.clobbered.*; do
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
    if [ -n "${1:-}" ] && [ -L "${d%/*}" ]; then die "${d%/*} is a symlink; refusing to move config backups into it"; fi
    if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then die "$d is a symlink or not a directory; refusing to move config backups into it"; fi
    if [ ! -d "$d" ]; then
      if [ -n "${1:-}" ] && [ ! -d "${d%/*}" ]; then mkdir -m 700 "${d%/*}"; fi
      mkdir -m 700 "$d"
    fi
    if [ -e "$d/${f##*/}" ] || [ -L "$d/${f##*/}" ]; then die "$d/${f##*/} exists already; refusing to overwrite a config backup"; fi
    mv "$f" "$d/${f##*/}"
    n=$((n + 1))
  done
  if [ "$n" -gt 0 ]; then echo "import: moved $n openclaw.json backup(s) of $arch_home aside to $d"; fi
}
if [ "$rehome" = 1 ]; then config_backups_aside; fi
# Automations stay off from the moment the state lands (and has its paths moved, and admin's config backups are aside:
# both must precede the first openclaw command), before any other step can fail.
if [ "$no_wa" = 1 ]; then openclaw config set cron.enabled false; fi   # key per docs/verification.md
# A rehearsal or drill gateway must never publish itself on the tailnet (and would not start logged out).
if [ "$no_wa" = 1 ] && [ -n "$ts_mode" ] && [ "$ts_mode" != off ]; then
  echo "import: gateway.tailscale.mode was '$ts_mode'; setting it to off for a $mode"
  openclaw config set gateway.tailscale.mode off
fi

# File state. The archive's wacli session and carried WhatsApp credential copies never reach the disk in
# rehearsal and drill. On the same home the guest already has authorized_keys entries of its own (Lima's): keep
# them. From another home (the bot account) the archive's login keys stay behind; only its deploy key, config
# and known_hosts land.
tar_excl=()
if [ "$no_wa" = 1 ]; then tar_excl=(--exclude '.wacli/session.db*' --exclude '.openclaw*/credentials/whatsapp*'); fi
if [ "$rehome" = 1 ]; then tar_excl+=(--exclude '.ssh/authorized_keys*'); fi
ak="$H/.ssh/authorized_keys"
prev_keys=$(cat "$ak" 2>/dev/null || true)
tar_sel=()
if [ "$rehome" = 1 ]; then
  # Only the deploy key, its public half, the ssh config and known_hosts of the archive's .ssh land; every other
  # member is left in the archive (nothing of it is ever extracted). The member list excludes whole .ssh
  # directory entries too: extracting one would bring its contents. Names only are printed.
  sel=$(mktemp "$H/.import-members.XXXXXX")
  skipped=""
  while IFS= read -r m; do
    case "$m" in
      .ssh/ocsb_vault|.ssh/ocsb_vault.pub|.ssh/config|.ssh/known_hosts|./.ssh/ocsb_vault|./.ssh/ocsb_vault.pub|./.ssh/config|./.ssh/known_hosts) printf '%s\n' "$m" >> "$sel" ;;
      .ssh|.ssh/*|./.ssh|./.ssh/*) skipped="${skipped:+$skipped }$m" ;;
      *) printf '%s\n' "$m" >> "$sel" ;;
    esac
  done <<<"$files_list"
  if [ -n "$skipped" ]; then echo "import: not restoring .ssh members from another home: $skipped" >&2; fi
  # --no-recursion: GNU tar credits every member under a listed directory entry (brain/, ops/) to that one entry
  # and then reports the nested members "Not found in archive".
  tar_sel=(--no-recursion -T "$sel")
fi
tar -C "$H" ${tar_excl[@]+"${tar_excl[@]}"} -xzf "$src/filestate.tar.gz" ${tar_sel[@]+"${tar_sel[@]}"}
if [ -n "$sel" ]; then rm -f "$sel"; sel=""; fi
# .ssh must be a real directory before anything below removes, merges or chmods in it (the cross-home end-state check,
# the same-home key merge, the modes): through a symlinked .ssh all of it would act on the link's target, and the
# end-state check would see nothing. Only the link itself is removed.
if [ -L "$H/.ssh" ] || { [ -e "$H/.ssh" ] && [ ! -d "$H/.ssh" ]; }; then rm -f "$H/.ssh"; die ".ssh in the archive is not a directory (removed)"; fi
if [ "$rehome" = 1 ]; then
  # Whatever tar did (GNU tar follows a symlink the archive itself created), the bot's .ssh ends up with only the four
  # allowed names, each a plain file. Everything else is removed, the modes are applied, and then the import dies;
  # a login key is removed by refuse_ssh_login. Names only are printed.
  bad=""
  for n in config known_hosts ocsb_vault ocsb_vault.pub; do
    if [ -L "$H/.ssh/$n" ] || { [ -e "$H/.ssh/$n" ] && [ ! -f "$H/.ssh/$n" ]; }; then
      rm -rf "${H:?}/.ssh/$n"; bad="${bad:+$bad }$n"
    fi
  done
  if [ -d "$H/.ssh" ]; then
    while IFS= read -r -d '' e; do
      n="${e##*/}"
      case "$n" in config|known_hosts|ocsb_vault|ocsb_vault.pub|authorized_keys|authorized_keys2) continue ;; esac
      rm -rf "$e"; bad="${bad:+$bad }$n"
    done < <(find "$H/.ssh" -mindepth 1 -maxdepth 1 -print0)
    chmod 700 "$H/.ssh"
    find "$H/.ssh" -maxdepth 1 -type f -exec chmod 600 {} +
  fi
  if [ -n "$bad" ]; then echo "import: removed .ssh entries the bot account may not have: $bad" >&2; fi
  refuse_ssh_login rm
  [ -z "$bad" ] || die ".ssh entries not allowed for the bot account were in the archive (removed, names above)"
fi
if [ "$rehome" = 0 ] && [ -n "$prev_keys" ]; then
  { printf '%s\n' "$prev_keys"; cat "$ak"; } | awk 'NF && !seen[$0]++' > "$ak.merged"
  mv "$ak.merged" "$ak"
fi
if [ -d "$H/.ssh" ]; then
  chmod 700 "$H/.ssh"
  find "$H/.ssh" -maxdepth 1 -type f -exec chmod 600 {} +
fi
[ -f "$envsrc" ] || die "restore did not produce $envsrc"
chmod 600 "$envsrc"
# A session or credential copy already on this box (an earlier import) is not ours to delete silently.
if [ "$no_wa" = 1 ]; then
  left=$({ find "$H/.openclaw/credentials" "$H"/.openclaw-stale-*/credentials -mindepth 1 -maxdepth 1 -name 'whatsapp*'; find "$H/.wacli" -name 'session.db*'; } 2>/dev/null || true)
  [ -z "$left" ] || die "WhatsApp credentials are present under $H after the strip (an earlier import on this box?); refusing to start a gateway"
fi

# The old VM's ~/ops carries its macOS listener guard (run by launchd) and its logs; the Linux guard is
# installed below. Retire exactly those files (an explicit list, no globbing) so dead launchctl code does not
# live here and the scans do not trip on their old paths. They remain in the export archive and the safety copies.
for f in ops/listener-guard/listener-guard.mjs ops/listener-guard/launchd.out.log ops/listener-guard/launchd.err.log; do
  if [ -e "$H/$f" ]; then rm -f "$H/$f"; echo "import: retired the macOS listener guard file $f"; fi
done

# The archive's home in the live configuration becomes this home (spec 2026-10-02 §2 step 4) before anything runs on
# it. Whatever the rewrite cannot reach (free text, a file that is not JSON) fails the import here: before npm ci,
# the token or the gateway. Transcripts and databases keep their history. Only roots that exist are named: the
# scan fails (exit 4) on a missing one by design; scan-refs skips vault directories, so the vault's git config is
# named itself.
home_scan() {
  local out rc=0
  local -a roots=()
  home_roots "$H" roots
  [ "${#roots[@]}" -gt 0 ] || die "no live configuration to scan under $H after the restore"
  out=$(SCAN_ALLOW="$repo/migrate/scan-allow.txt" node "$repo/migrate/scan-refs.mjs" --old-home "$arch_home" ${roots[@]+"${roots[@]}"} 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  case "$rc" in
    0) ;;
    1) die "the live configuration still names $arch_home (see above): make it home-relative at the source, or teach migrate/homepaths.mjs that file" ;;
    *) die "the leftover scan could not run (exit $rc: $(printf '%s\n' "$out" | tail -1))" ;;
  esac
}
if [ "$rehome" = 1 ]; then
  # The drill's own config writes above rotated .bak* of the landed, not yet rewritten config (it names the old home):
  # a second pass, into its own subdir so the first pass's name-clash refusal is not hit. Final mode has written no
  # config yet: nothing to move.
  config_backups_aside drill-writes
  node "$repo/migrate/homepaths.mjs" "$arch_home" "$H" || die "the home rewrite failed (see above)"
  home_scan
fi

for p in "$H"/brain/*/package-lock.json; do
  [ -f "$p" ] || continue
  (cd "$(dirname "$p")" && npm ci --no-audit --no-fund)
done
# Only now may the token reach child processes.
export OP_SERVICE_ACCOUNT_TOKEN="$tok"

# --- platform changes ---------------------------------------------------------------------
node "$repo/migrate/binpaths.mjs" "$H"
openclaw config set plugins.entries.imessage.enabled false
# `config unset` exits 1 when the path is absent (a backup without iMessage); anything else is a real error.
if ! unset_out=$(openclaw config unset channels.imessage 2>&1); then
  case "$unset_out" in *"Config path not found"*) echo "import: channels.imessage not present; nothing to unset" ;; *) echo "$unset_out" >&2; die "config unset channels.imessage failed" ;; esac
fi

# --- service: OpenClaw's own systemd unit, bootstrap token carried over -----------------------
# `gateway install` writes no service-env/*.env on Linux and does not copy the token from its own
# environment into the unit; a reinstall was observed emptying a hand-written gateway.systemd.env of a
# key that an exec SecretRef provider lists in passEnv. The state-dir ~/.openclaw/.env is OpenClaw's
# documented global env file: the service and the CLI both load it, and install/doctor leave it alone
# (verified on the guest, recorded in docs/verification.md).
dotenv="$H/.openclaw/.env"
(
  umask 077
  # Every form of the key goes (export-prefixed, indented, spaced), so the new line is the only assignment.
  { grep -Ev '^[[:space:]]*(export[[:space:]]+)?OP_SERVICE_ACCOUNT_TOKEN[[:space:]]*=' "$dotenv" 2>/dev/null || true; printf 'OP_SERVICE_ACCOUNT_TOKEN=%s\n' "$tok"; } > "$dotenv.new"
  mv "$dotenv.new" "$dotenv"
)
chmod 600 "$dotenv"
openclaw gateway install --runtime-path /usr/bin/node --force
# `gateway install` also starts the unit. doctor's state maintenance needs the state offline: a gateway
# that keeps restarting meanwhile fails on "undergoing offline maintenance" and trips the start limit.
systemctl --user stop "$GATEWAY_UNIT"
openclaw doctor --fix --non-interactive --allow-exec --yes
systemctl --user reset-failed "$GATEWAY_UNIT" 2>/dev/null || true
systemctl --user cat "$GATEWAY_UNIT" >/dev/null 2>&1 || die "gateway install did not create $GATEWAY_UNIT (update GATEWAY_UNIT here and GUARD_RESTART for the guard)"
# The managed browser needs a display: without one OpenClaw launches Chromium headless, and Cloudflare blocks
# HeadlessChrome. The drop-in gives the gateway DISPLAY; installed after `gateway install`, which rewrites the unit.
install -d "$H/.config/systemd/user/$GATEWAY_UNIT.d"
cp "$repo/ops/browser-display/openclaw-xvfb.service" "$H/.config/systemd/user/"
cp "$repo/ops/browser-display/browser-display.conf" "$H/.config/systemd/user/$GATEWAY_UNIT.d/"
systemctl --user daemon-reload
systemctl --user enable --now openclaw-xvfb.service
systemctl --user enable --now "$GATEWAY_UNIT"

# --- command automations: argv[0] to Debian paths, via OpenClaw's own CLI -------------------
OPENCLAW_GATEWAY_TOKEN=$(op read "op://Sebastian/OpenClaw Gateway Token/password") || die "cannot read the gateway token from 1Password"
export OPENCLAW_GATEWAY_TOKEN
deadline=$((SECONDS + 90))
until timeout 10 openclaw gateway call health --json >/dev/null 2>&1; do
  [ "$SECONDS" -lt "$deadline" ] || die "gateway answered no authenticated health call within 90s (journalctl --user -u $GATEWAY_UNIT)"
  sleep 2
done
# shellcheck disable=SC2016  # the JavaScript is meant to reach node unexpanded
openclaw automations list --all --json | node --input-type=module -e '
  import path from "node:path";
  import { pathToFileURL } from "node:url";
  import { execFileSync } from "node:child_process";
  const { rewriteArgv, DEFAULT_MAP } = await import(pathToFileURL(path.join(process.argv[1], "migrate/binpaths.mjs")).href);
  let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
    const j = JSON.parse(s); const jobs = j.automations ?? j.jobs ?? j;
    for (const x of jobs) {
      const argv = x.payload?.argv; if (x.payload?.kind !== "command" || !argv) continue;
      const r = rewriteArgv(argv, DEFAULT_MAP); if (!r.changed) continue;
      execFileSync("openclaw", ["cron", "edit", x.id, "--command-argv", JSON.stringify(r.argv)], { stdio: "inherit" });
      console.log(`automation ${x.name}: argv[0] ${argv[0]} -> ${r.argv[0]}`);
    }
  });' "$repo"

# --- guard + gates ----------------------------------------------------------------------------
install -d "$H/.config/systemd/user" "$H/ops/listener-guard"
cp "$repo/ops/listener-guard/guard.mjs" "$H/ops/listener-guard/"
cp "$repo/ops/listener-guard/"*.service "$repo/ops/listener-guard/"*.timer "$H/.config/systemd/user/"
if [ "$mode" = final ]; then
  install -d "$H/ops/backup" "$H/ops/lib"
  cp "$repo/ops/backup/nightly-backup.sh" "$repo/ops/backup/backup-health.mjs" "$H/ops/backup/"
  cp "$repo/ops/lib/dotenv-token.sh" "$H/ops/lib/"
  cp "$repo/ops/backup/"*.service "$repo/ops/backup/"*.timer "$H/.config/systemd/user/"
fi
systemctl --user daemon-reload
systemctl --user enable --now openclaw-listener-guard.timer
if [ "$mode" = final ]; then systemctl --user enable --now openclaw-nightly-backup.timer; fi

SCAN_ALLOW="$repo/migrate/scan-allow.txt" node "$repo/migrate/scan-refs.mjs" "$H/brain" "$H/ops" "$H/.openclaw/workspace/skills" "$H/.openclaw/workspace-vera/skills" \
  || die "free-text scan found references that break on Linux (see above); fix or allow-list them"
# doctor and the gateway have worked on the state since: still nothing in live configuration names the old home.
if [ "$rehome" = 1 ]; then home_scan; fi
openclaw secrets audit --allow-exec --check || die "secrets audit reported findings (see above)"
case "$mode" in final) acc=final ;; *) acc=rehearsal ;; esac   # acceptance.sh knows rehearsal|final; a drill is checked as a rehearsal
echo "import: done ($mode). Now run tests/acceptance.sh $acc <lan-ip>"
