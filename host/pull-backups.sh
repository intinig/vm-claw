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
# A .partial may hold a read-only directory (tar applies the archived modes): make it removable first.
rm_part() { chmod -R u+rwX "$1" 2>/dev/null || true; rm -rf "$1"; }
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
  if [ -L "$1" ] || [ ! -d "$1" ]; then return 1; fi
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
  if [ -n "$part" ]; then rm_part "$part"; fi
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
    rm_part "$part"; mkdir -m 700 "$part"
    why=""
    # The guest's tar runs as the bot (only it can read its home); the host unpacks into the .partial and nowhere else.
    if ! "${as_bot[@]}" tar -C "$gb" -cf - "$name" | tar -xf - -C "$part"; then
      why="the copy from the guest failed (pruned meanwhile?)"
    elif ! verify "$part/$name"; then
      why="it failed verification (MANIFEST, checksums, or files a nightly does not write)"
    fi
    if [ -n "$why" ]; then
      rm_part "$part"; part=""
      echo "pull-backups: $name: $why; not keeping it" >&2
      failed+=("$name")
    else
      chmod 700 "$part/$name"; chmod 600 "$part/$name"/*
      mv "$part/$name" "$dest/$name"
      rm_part "$part"; part=""
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
for d in "$dest"/claw-nightly-*.partial; do
  if [ -e "$d" ]; then rm_part "$d"; fi
done

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
