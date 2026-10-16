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
# Knobs for migrate/rehome.test.sh only: REHOME_VARLIB (default /var/lib), REHOME_GW_LOGDIR (default /tmp/openclaw),
# REHOME_LOCK, REHOME_SCRATCHDIR (default /tmp: never under $HOME, so the scan copy cannot copy itself).
set +x   # import.sh and the nightly handle tokens: a traced run must not print them
set -Eeuo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
# shellcheck source=provision/bot.sh
. "$repo/provision/bot.sh"
# shellcheck source=migrate/lib/home-roots.sh
. "$repo/migrate/lib/home-roots.sh"
varlib="${REHOME_VARLIB:-/var/lib}"
state="$varlib/claw-rehome"            # root-only record of what each phase completed
gwlog="${REHOME_GW_LOGDIR:-/tmp/openclaw}"
me=$(id -un)
# The scratch copy of admin's configuration (prepare's leftover scan) holds .env files with the gateway token: it is
# removed on every way out, a signal included.
scratch=""
phase=""; died=""; errline=""; stop_hint=""
# A raw `set -e` failure (a command nobody wrote a message for) says where it stopped and what is recorded, so the owner
# is never left with only a bare exit status. die and usage have said their own piece already.
on_exit() {
  local rc=$? recs=""
  [ -z "$scratch" ] || rm -rf "$scratch"
  if [ "$rc" -ne 0 ] && [ -z "$died" ] && [ -n "$phase" ]; then
    recs=$(sudo -n ls "$state" 2>/dev/null | tr '\n' ' ' || true)
    echo "rehome: rehome.sh $phase failed (line ${errline:-?}); records: ${recs:-none}; see README \"Move the bot to its own account\"" >&2
  fi
}
trap on_exit EXIT
trap 'errline=$LINENO' ERR
trap 'exit 1' INT TERM HUP
die() { died=1; echo "rehome: $*" >&2; exit 1; }
usage() { died=1; echo "usage: $0 prepare | switch final|drill | verify final|rehearsal <lan-ip> | retire | rollback" >&2; exit 2; }
# The guard goes first (a guard run in flight can restart the gateway), the gateway last; started the other way round.
# The nightly service stops too: one in flight must not have state moved out from under it.
STOP_UNITS=(openclaw-listener-guard.timer openclaw-listener-guard.service openclaw-nightly-backup.timer openclaw-nightly-backup.service openclaw-gateway.service)
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
      *) die "$who's $u is '${st:-unknown}' after disable --now; refusing to go on (two gateways must never share WhatsApp)${stop_hint:+; $stop_hint}" ;;
    esac
  done
  echo "rehome: $who's gateway, guard and nightly timer and service are stopped and disabled"
}

# leftover_scan: what import.sh would refuse mid-downtime, found while production still runs. admin's live roots (the
# list import.sh scans, from migrate/lib/home-roots.sh) are copied into a private scratch home, rewritten with
# homepaths.mjs as the import will, and scanned for what still names admin's home. Read-only on admin's home. Prints
# scan-refs' own output (file names and counts), never file contents.
leftover_scan() {
  local r rel out rc=0
  local -a tarrc=()
  local -a roots=() copied=()
  scratch=$(mktemp -d "${REHOME_SCRATCHDIR:-/tmp}/claw-rehome-scan.XXXXXX") || die "cannot create a scratch directory for the leftover scan"
  chmod 700 "$scratch"
  home_roots "$HOME" roots
  for r in ${roots[@]+"${roots[@]}"}; do
    rel="${r#"$HOME"/}"
    if [ "$rel" = brain ]; then
      # The vault is not scanned (scan-refs skips it) and can be large: its git config is its own root.
      mkdir -p "$scratch/brain"
      # .git is not scanned either. GNU tar exits 1 when a file changed as it was read: a live brain does that, and
      # the scan does not mind. Exit 2 or more (a cd that fails included), or a failing extract, is fatal.
      # The ERR trap is off for this one pipeline: bash 3.2 runs it on a failing pipeline even under set +e, and that
      # resets PIPESTATUS before it can be read.
      set +e; trap - ERR
      (cd "$r" || exit 2; tar -cf - --exclude=./vault --exclude=.git --exclude=node_modules .) | tar -xf - -C "$scratch/brain"
      tarrc=("${PIPESTATUS[@]}")
      trap 'errline=$LINENO' ERR; set -e
      [ "${tarrc[1]}" -eq 0 ] && [ "${tarrc[0]}" -le 1 ] || die "cannot copy $r for the leftover scan"
      if [ "${tarrc[0]}" -eq 1 ]; then echo "prepare: brain changed during the dry-scan copy (harmless for the scan)"; fi
    else
      mkdir -p "$scratch/$(dirname "$rel")"
      cp -a "$r" "$scratch/$rel" || die "cannot copy $r for the leftover scan"
    fi
  done
  node "$repo/migrate/homepaths.mjs" "$HOME" "$scratch" >/dev/null || die "prepare: the home rewrite on the scratch copy failed (see above)"
  home_roots "$scratch" copied
  [ "${#copied[@]}" -gt 0 ] || die "prepare: no live configuration to scan under $HOME"
  out=$(SCAN_ALLOW="$repo/migrate/scan-allow.txt" node "$repo/migrate/scan-refs.mjs" --old-home "$HOME" ${copied[@]+"${copied[@]}"} 2>&1) || rc=$?
  [ -z "$out" ] || printf '%s\n' "${out//$scratch/<scratch>}"
  case "$rc" in
    0) ;;
    1) die "prepare: admin's live configuration still names $HOME (see above): make it home-relative at the source, or teach migrate/homepaths.mjs that file" ;;
    *) die "prepare: the leftover scan could not run (exit $rc: $(printf '%s\n' "$out" | tail -1))" ;;
  esac
  rm -rf "$scratch"; scratch=""
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
  leftover_scan
  # The import rewrites the memory notes' project annotations in every workspace* (homepaths.mjs) and refuses a
  # symlinked directory there: the same walk over admin's live workspaces, read-only, finds one now.
  node "$repo/migrate/homepaths.mjs" --check-notes "$HOME" \
    || die "prepare: a workspace of admin's holds what the import's note rewrite refuses (see above): resolve it while production runs; production untouched"
  # What would make the state-path migration refuse mid-downtime, found now (spec addendum 2026-10-05): python 3.9+
  # with sqlite3, the OpenClaw pin, and a dry run of the migration on copies of admin's live databases under a scratch
  # home in the scratch knob, removed on exit. Read-only on admin's state.
  TMPDIR="${REHOME_SCRATCHDIR:-/tmp}" python3 "$repo/migrate/state-paths.py" preflight --home "$HOME" \
    || die "prepare: the state-path preflight refused (see above): fix it while production runs; production untouched"
  echo "prepare: OK ($BOT_USER is ready; production untouched)"
}

# The gateway's automation count: `<cmd…> cron list --all --json | jq .total`, printed when numeric. A gateway that is
# still starting answers null, nothing or garbage: that is read again for up to 60 s (12 retries, 5 s apart; the knobs
# are the tests'). A numeric answer, whatever it is, ends the reading at once. Prints "" when still unreadable.
read_cron_total() {
  local v="" tries=0 max="${REHOME_CRON_RETRIES:-12}"
  while :; do
    if ! v=$("$@" cron list --all --json | jq .total); then v=""; fi
    if [[ "$v" =~ ^[0-9]+$ ]] || [ "$tries" -ge "$max" ]; then break; fi
    tries=$((tries + 1))
    sleep "${REHOME_CRON_RETRY_SLEEP:-5}"
  done
  [[ "$v" =~ ^[0-9]+$ ]] || v=""
  printf '%s\n' "$v"
}

switch() {
  local mode="$1" ts night copy n d ct
  prepare
  if marked switched; then die "a switch is already recorded ($(mark_value switched)): rehome.sh rollback first"; fi
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  # 0. admin's automation count, from its running gateway: verify checks the bot's against it (state-paths.py check,
  #    spec addendum 2026-10-05). A count that cannot be read stops the switch here, before the downtime.
  ct=$(read_cron_total openclaw)
  [[ "$ct" =~ ^[0-9]+$ ]] || die "cannot read admin's automation count (openclaw cron list --all --json | jq .total); nothing was stopped"
  sudo -n install -d -m 700 "$state"
  mark cron-total "$ct"
  echo "rehome: admin's gateway lists $ct automation(s); recorded for verify"
  # 1. admin's gateway, guard and nightly timer: off, and proven off.
  stop_hint="nothing was imported; run rehome.sh rollback to bring admin's gateway back"
  stop_units admin
  stop_hint=""
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
  # The gateway logs under $gwlog and the guard reads it. Left as admin's, the bot's gateway would log elsewhere and
  # the guard would judge admin's old lines: set admin's aside; the bot's gateway makes its own. Only now: the nightly
  # above runs the OpenClaw CLI as admin, which recreates $gwlog as admin 700 (the bot's gateway would get EACCES).
  # Still before anything of the bot's starts (the copy and the import below).
  if [ -e "$gwlog" ]; then sudo -n mv "$gwlog" "$gwlog.pre-rehome-$ts"; echo "rehome: admin's gateway logs moved to $gwlog.pre-rehome-$ts"; fi
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
  mark imported "$mode $(date -u +%Y%m%dT%H%M%SZ)"   # switched is written before the import; verify needs this one
  echo "switch: done ($mode, $night). Next: rehome.sh verify $(acc_mode "$mode") <lan-ip>"
}

verify() {
  local amode="$1" lan="$2" smode accrc=0 ct gw vfail=""
  marked switched || die "no switch is recorded: run rehome.sh switch first"
  marked imported || die "the recorded switch has no successful import (it failed): rehome.sh rollback, then switch again"
  smode=$(mark_value switched | cut -d' ' -f1)
  [ "$(acc_mode "$smode")" = "$amode" ] || die "the recorded switch is '$smode': verify it as '$(acc_mode "$smode")'"
  ct=$(mark_value cron-total 2>/dev/null || true)
  [[ "$ct" =~ ^[0-9]+$ ]] || die "no automation count is recorded for this switch (cron-total): rehome.sh rollback, then switch again"
  as_bot bash "$repo/tests/acceptance.sh" "$amode" "$lan" || accrc=$?
  case "$accrc" in
    # After the first start (spec addendum 2026-10-05): the automations as the bot's gateway itself lists them (§8.5
    # item 1: rows it cannot see do not count), then the cron rows, declarations, workspace rows, the exec-approvals
    # socket, plugin keys and Workshop proposals as the state-path migration left them. Both always run; either fails.
    0) gw=$(read_cron_total as_bot openclaw)
       if ! [[ "$gw" =~ ^[0-9]+$ ]]; then vfail="cannot read the bot's automation count (openclaw cron list --all --json | jq .total); the gateway may still be starting: run rehome.sh verify again"
       elif [ "$gw" != "$ct" ]; then vfail="the bot's gateway lists $gw automation(s), admin's listed $ct"
       else echo "verify: the bot's gateway lists $gw automation(s), as admin's did"; fi
       if ! as_bot python3 "$repo/migrate/state-paths.py" check --home "$BOT_HOME" --cron-total "$ct"; then
         vfail="${vfail:+$vfail; }the state-path check FAILED (see above)"
       fi
       [ -z "$vfail" ] || die "$vfail: fix forward, or rehome.sh rollback"
       mark verified "$amode $(date -u +%Y%m%dT%H%M%SZ)"
       echo "verify: PASS. The owner confirms the MANUAL lines above; then rehome.sh retire" ;;
    2) died=1; echo "rehome: verify: acceptance rejected its arguments (usage error, exit 2: check '$lan'); nothing was tested and no pass is recorded" >&2; exit 2 ;;
    *) die "acceptance FAILED (see above): fix forward, or rehome.sh rollback" ;;
  esac
}

retire() {
  local st day dest del it g p
  local -a moved=()
  marked verified || die "no passing verify is recorded: run rehome.sh verify first"
  if marked retired; then die "retire already ran: $(mark_value retired)"; fi
  st=$(as_bot systemctl --user is-active openclaw-gateway.service 2>/dev/null || true)
  [ "$st" = active ] || die "the bot's gateway is '${st:-unknown}', not active: admin's copy stays where it is"
  stop_hint="nothing was moved; admin's copy stays where it is"
  stop_units admin
  stop_hint=""
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
  # The manifest first, as RETIRING: a retire that dies half-way leaves the exact list; RETIRED appears only at the end,
  # and rollback restores only from a RETIRED.
  del=$(date -u -d "+14 days" +%Y-%m-%d)
  { printf 'retired %s from %s; delete after %s (README "Retire")\n' "$day" "$HOME" "$del"; printf '%s\n' "${moved[@]}"; } \
    | sudo -n tee "$dest/RETIRING" >/dev/null
  for it in "${moved[@]}"; do
    sudo -n mkdir -p "$dest/home/$(dirname "$it")"
    sudo -n mv "$HOME/$it" "$dest/home/$it"
  done
  for p in "$HOME"/.config/systemd/user/openclaw-*.service "$HOME"/.config/systemd/user/openclaw-*.timer; do
    if [ -e "$p" ]; then sudo -n mv "$p" "$dest/units/"; fi
  done
  systemctl --user daemon-reload
  sudo -n loginctl disable-linger "$me"
  for it in "${moved[@]}"; do if [ -e "$HOME/$it" ]; then die "$HOME/$it is still there after the move"; fi; done
  sudo -n mv "$dest/RETIRING" "$dest/RETIRED"
  mark retired "$dest"
  echo "retire: admin's copy is in $dest (root only); delete it after $del"
}

rollback() {
  local ts src="" n=0 r st aside it p u wa fam carried=0 baside items="" bad=""
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  sudo -n install -d -m 700 "$state"
  for r in "$varlib"/claw-retired-admin-*; do
    case "$r" in *.restored-by-hand) continue ;; esac   # a retired dir the owner emptied by hand and moved aside (R)
    if sudo -n test -d "$r"; then n=$((n + 1)); src="$r"; fi
  done
  [ "$n" -le 1 ] || die "more than one retired copy in $varlib (claw-retired-admin-*): restore one by hand (README \"Rollback\")"
  if [ -z "$src" ] && [ ! -f "$HOME/.openclaw/openclaw.json" ]; then die "neither $HOME/.openclaw nor a retired copy exists: nothing to roll back to"; fi
  # 0. Read-only preflight, before anything is stopped: restoring the retired copy must be possible in full, or
  #    nothing starts (a rollback that stops the bot and then refuses leaves no gateway at all).
  if [ -n "$src" ]; then
    if ! sudo -n test -f "$src/RETIRED"; then
      die "no readable $src/RETIRED: nothing was stopped. If $src/RETIRING exists, a retire died half-way: it lists what that retire meant to move, and the listed items that are present under $src/home are the ones that moved. Move each of those back to the same path under $HOME by hand (and any unit files in $src/units to $HOME/.config/systemd/user), then move the emptied retired dir aside with: sudo mv $src $src.restored-by-hand (this rollback ignores a dir with that suffix), and run rehome.sh rollback again (README \"Rollback\")"
    fi
    items=$(sudo -n sed -n '2,$p' "$src/RETIRED")
    while IFS= read -r it; do
      [ -n "$it" ] || continue
      if [ -e "$HOME/$it" ] || [ -L "$HOME/$it" ]; then bad="$bad $HOME/$it (exists in admin's home)"$'\n'; fi
      if ! sudo -n test -e "$src/home/$it" && ! sudo -n test -L "$src/home/$it"; then bad="$bad $src/home/$it (missing from the retired copy)"$'\n'; fi
    done <<<"$items"
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      if [ -e "$HOME/.config/systemd/user/$u" ] || [ -L "$HOME/.config/systemd/user/$u" ]; then bad="$bad $HOME/.config/systemd/user/$u (exists in admin's home)"$'\n'; fi
    done < <(sudo -n ls -A "$src/units")
    # admin's own bot state next to a retired copy: a collision like any other, named with the rest (items has .openclaw)
    case "$bad" in *" $HOME/.openclaw ("*) ;; *) if [ -e "$HOME/.openclaw" ]; then bad="$bad $HOME/.openclaw (exists in admin's home)"$'\n'; fi ;; esac
    if [ -n "$bad" ]; then die "cannot restore $src, nothing was stopped or moved; resolve these first:"$'\n'"${bad%$'\n'}"; fi
  fi
  # 1. The bot's units off, and proven off: from here on no gateway runs. admin's too, whatever way rollback was
  #    entered: its WhatsApp files are swapped below and no gateway may hold them.
  stop_units bot
  stop_units admin
  # 2. admin's data back in place, if retire moved it (root's mv keeps admin as the owner).
  if [ -n "$src" ]; then
    while IFS= read -r it; do
      [ -n "$it" ] || continue
      if [ -e "$HOME/$it" ]; then die "$HOME/$it exists; not overwriting it with the retired copy"; fi
      mkdir -p "$HOME/$(dirname "$it")"
      sudo -n mv "$src/home/$it" "$HOME/$it"
    done <<<"$items"
    mkdir -p "$HOME/.config/systemd/user"
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      sudo -n mv "$src/units/$u" "$HOME/.config/systemd/user/$u"
    done < <(sudo -n ls -A "$src/units")
    [ -z "$(sudo -n find "$src/home" -mindepth 1 ! -type d -print)" ] || die "files are left in $src/home after the restore; look before deleting it"
    sudo -n rm -rf "$src"
    echo "rehome: admin's copy is back from $src"
  fi
  # Always: a retire that died after disable-linger, or a hand restore, must not leave admin without linger.
  sudo -n loginctl enable-linger "$me"
  # 3. The bot's WhatsApp state is newer than admin's (its gateway ran since the switch). Two families, each handled on
  #    its own: the credentials (.openclaw/credentials/whatsapp*) and wacli's session (.wacli/session.db*, -wal and -shm
  #    included). Only a family the bot actually has replaces admin's: admin's own set of that family goes aside first,
  #    so nothing stale mixes with it; a family the bot lacks leaves admin's untouched (moving it aside unreplaced would
  #    silently unpair it). Then the bot's is copied over, as admin.
  aside="$HOME/.claw-rollback-aside-$ts"
  for fam in '.openclaw/credentials/whatsapp*' '.wacli/session.db*'; do
    # shellcheck disable=SC2016  # expanded by root's bash
    wa=$(sudo -n bash -c 'cd "$1" 2>/dev/null && { ls -d $2 2>/dev/null || true; }' _ "$BOT_HOME" "$fam")
    [ -n "$wa" ] || continue
    [ -d "$aside" ] || mkdir -m 700 "$aside"
    # shellcheck disable=SC2231  # $fam is a glob on purpose
    for p in "$HOME"/$fam; do
      if [ -e "$p" ]; then mkdir -p "$aside/$(dirname "${p#"$HOME"/}")"; mv "$p" "$aside/${p#"$HOME"/}"; fi
    done
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      mkdir -p "$HOME/$(dirname "$p")"
      sudo -n cp -a "$BOT_HOME/$p" "$HOME/$p"
      sudo -n chown -R "$me:$(id -gn)" "$HOME/$p"
      carried=$((carried + 1))
    done <<<"$wa"
  done
  if [ "$carried" -gt 0 ]; then echo "rehome: carried $carried WhatsApp item(s) back to admin; admin's earlier ones are in $aside"; fi
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
  # 5. admin's units on again, but only while the bot's gateway is still proven down (two gateways must never share WhatsApp).
  systemctl --user daemon-reload
  st=$(as_bot systemctl --user is-active openclaw-gateway.service 2>/dev/null || true)
  case "$st" in
    inactive|failed) ;;
    *) die "the bot's openclaw-gateway.service is '${st:-unknown}' before admin's units are enabled; refusing to start a second gateway on WhatsApp" ;;
  esac
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
  sudo -n rm -f "$state/switched" "$state/imported" "$state/verified" "$state/retired" "$state/cron-total"
  if [ -n "$src" ]; then mark "rolled-back-$ts" "from $src"; else mark "rolled-back-$ts" "from admin's home"; fi
  echo "rollback: done; admin's gateway is active. Check WhatsApp: openclaw channels status (linked, running, connected)"
}

# One phase at a time: every phase takes this exclusive lock after its arguments are checked (usage errors need none).
# fd 9 holds it until the script exits. No lock, no phase.
take_lock() {
  local lock="${REHOME_LOCK:-/run/lock/claw-rehome.lock}"
  # shellcheck disable=SC2015  # die must run when either the open or the flock fails
  exec 9>"$lock" && flock -n 9 || die "another rehome.sh is running (lock $lock)"
}

[ "$(id -u)" != 0 ] || die "run as admin, not as root"
[ "$me" != "$BOT_USER" ] || die "run as admin, not as $BOT_USER"
phase="${1:-}"
case "$phase" in
  prepare)  [ "$#" -eq 1 ] || usage; take_lock; prepare ;;
  switch)   [ "$#" -eq 2 ] || usage; case "$2" in final|drill) ;; *) usage ;; esac; take_lock; switch "$2" ;;
  verify)   [ "$#" -eq 3 ] || usage; case "$2" in final|rehearsal) ;; *) usage ;; esac; take_lock; verify "$2" "$3" ;;
  retire)   [ "$#" -eq 1 ] || usage; take_lock; retire ;;
  rollback) [ "$#" -eq 1 ] || usage; take_lock; rollback ;;
  *) usage ;;
esac
