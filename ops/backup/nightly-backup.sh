#!/bin/bash
# Guest nightly backup, run by openclaw-nightly-backup.timer. Same layout as a migration export
# (migrate/export.sh) with mode=nightly, so migrate/import.sh can restore it. Keeps the newest 7.
# It is built in claw-nightly-<ts>.partial (mode 700: it holds live secrets) and renamed to
# claw-nightly-<ts> only once its MANIFEST is written, so a complete directory is always whole and a
# failed run leaves nothing behind. Retention and the host pull match complete directories only.
# The OpenClaw CLI loads ~/.openclaw/.env (the 1Password bootstrap token) itself: nothing is sourced here.
# One run at a time: a mkdir lock in the backups dir (macOS has no flock, and this mirrors the host job).
set -euo pipefail
keep=7
root="$HOME/backups"
die() { echo "nightly-backup: $*" >&2; exit 1; }

lib="$(dirname "$0")/../lib/dotenv-token.sh"
[ -f "$lib" ] || die "$lib is missing (import.sh installs it next to ops/backup)"
# shellcheck source=ops/lib/dotenv-token.sh
. "$lib"

# The token's source of truth on this box. import.sh reads it from filestate.tar.gz with the same parser,
# so a backup whose token it would refuse could not be restored.
dotenv="$HOME/.openclaw/.env"
[ -f "$dotenv" ] || die "$dotenv is missing; a backup without the bootstrap token could not be restored"
dotenv_token "$dotenv" >/dev/null || die "$dotenv cannot yield the bootstrap token (see above); a backup without it could not be restored"
# This runs on the production guest, which import.sh final installs: what it archives must exist. Only the
# WhatsApp CLI store may be absent (a box that never linked one).
for need in brain .ssh ops; do
  [ -e "$HOME/$need" ] || die "$HOME/$need is missing; refusing to write a backup that silently leaves it out"
done
[ -e "$HOME/.wacli" ] || echo "nightly-backup: WARNING: $HOME/.wacli is missing; this backup has no WhatsApp CLI state" >&2

mkdir -p "$root"; chmod 700 "$root"
lock="$root/.lock"
have_lock=0; finished=0; out=""
cleanup() {
  if [ -n "$out" ] && [ "$finished" != 1 ]; then
    rm -rf "$out"
    echo "nightly-backup: failed; removed the incomplete $out" >&2
  fi
  if [ "$have_lock" = 1 ]; then rm -rf "$lock"; fi
  return 0
}
trap cleanup EXIT
if ! mkdir "$lock" 2>/dev/null; then
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
    # The run that held it is gone (killed, or the guest rebooted): take the lock over rather than let one
    # crash stop every later night.
    mv "$lock" "$lock.stale.$$" 2>/dev/null && rm -rf "$lock.stale.$$"
    mkdir "$lock" 2>/dev/null || die "another nightly backup took $lock just now"
  else
    die "another nightly backup holds $lock${holder:+ (pid $holder)}; if none is running, remove it"
  fi
fi
have_lock=1
echo "$$" > "$lock/pid"

# Complete backups, oldest first (the UTC timestamp in the name sorts chronologically; mtimes do not survive
# a copy). The pattern skips *.partial.
done_dirs=()
list_done() {
  local d
  done_dirs=()
  for d in "$root"/claw-nightly-*Z; do
    if [ -d "$d" ]; then done_dirs+=("$d"); fi
  done
}

# A full disk wedges the live gateway, so fail closed before writing anything: room for another backup of
# the size of the newest complete one (none yet: no size term) plus a 1 GiB margin.
list_done
prev_kb=0
if [ "${#done_dirs[@]}" -gt 0 ]; then
  prev_kb=$(du -sk "${done_dirs[${#done_dirs[@]}-1]}" | awk '{ print $1 }')
fi
need_kb=$((1048576 + prev_kb))
avail_kb=$(df -Pk "$HOME" | awk 'NR == 2 { print $4 }')
if [ "${avail_kb:-0}" -lt "$need_kb" ]; then
  die "not enough free space in $HOME: previous nightly $((prev_kb / 1024)) MiB + 1024 MiB margin = $((need_kb / 1024)) MiB needed, $((${avail_kb:-0} / 1024)) MiB free"
fi

name="claw-nightly-$(date -u +%Y%m%dT%H%M%SZ)"
final="$root/$name"
mkdir -m 700 "$final.partial"
out="$final.partial"

openclaw backup create --output "$out" --verify
shopt -s nullglob
backups=("$out"/*-openclaw-backup.tar.gz)
shopt -u nullglob
[ "${#backups[@]}" -eq 1 ] || die "expected one backup archive in $out, found ${#backups[@]}"
mv "${backups[0]}" "$out/openclaw-backup.tar.gz"

# What OpenClaw's own backup (only ~/.openclaw) leaves out. The retired agent dirs and stale state dirs next
# to it came from the old VM's export and may exist nowhere else.
items=()
for it in brain .wacli .ssh ops .openclaw/.env; do
  if [ -e "$HOME/$it" ]; then items+=("$it"); fi
done
for p in "$HOME"/openclaw-agents-retired-* "$HOME"/.openclaw-stale-*; do
  if [ -e "$p" ]; then items+=("${p#"$HOME"/}"); fi
done
# GNU tar exits 1 when a file changed while it was read (a live SQLite database): the archive is still
# written, so that does not fail the night. Exit 2 and up (unreadable or missing files, a full disk) does.
tar_rc=0
tar_msg=$(tar -C "$HOME" -czf "$out/filestate.tar.gz" --exclude 'brain/*/node_modules' "${items[@]}" 2>&1) || tar_rc=$?
if [ "$tar_rc" -ge 2 ]; then
  [ -z "$tar_msg" ] || echo "$tar_msg" >&2
  die "tar exited $tar_rc while writing filestate.tar.gz"
elif [ "$tar_rc" -eq 1 ]; then
  echo "nightly-backup: WARNING: tar exited 1 (a file changed while it was archived); keeping this backup. tar said: $tar_msg" >&2
elif [ -n "$tar_msg" ]; then
  echo "$tar_msg" >&2
fi

(cd "$out" && { echo "mode=nightly"; sha256sum openclaw-backup.tar.gz filestate.tar.gz; } > MANIFEST)
chmod 600 "$out"/*
[ ! -e "$final" ] || die "$final already exists; refusing to nest the new backup in it"
mv "$out" "$final"
finished=1

# Retention: keep the newest $keep complete backups. Then sweep .partial dirs a killed run left behind
# (safe: this run holds the lock).
list_done
i=0
while [ "$i" -lt $((${#done_dirs[@]} - keep)) ]; do
  rm -rf "${done_dirs[$i]}"
  i=$((i + 1))
done
rm -rf "$root"/claw-nightly-*.partial
du -sh "$final"
