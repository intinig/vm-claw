#!/bin/bash
# Run on the OLD (macOS) VM. Usage: export.sh rehearsal|final
# Writes $HOME/claw-export-<mode>-<UTC ts>/ holding openclaw-backup.tar.gz, filestate.tar.gz and a
# MANIFEST (a `mode=<mode>` line, then `sha256  file` lines). The directory holds live secrets:
# mode 700, and an incomplete one is removed again if the export fails.
# Final mode first stops the listener guard and the gateway; rehearsal never stops anything.
set -euo pipefail
mode="${1:-}"
case "$mode" in rehearsal|final) ;; *) echo "usage: $0 rehearsal|final" >&2; exit 2 ;; esac
export PATH=/opt/homebrew/bin:$PATH

items=(brain .wacli .ssh/ocsb_vault .ssh/ocsb_vault.pub .ssh/config .ssh/authorized_keys .ssh/known_hosts ops
       .openclaw/service-env/ai.openclaw.gateway.env)
# Retired agent dirs sit next to the state dir; match them under $HOME whatever the working directory is.
for p in "$HOME"/openclaw-agents-retired-* "$HOME"/.openclaw-stale-*; do
  if [ -e "$p" ]; then items+=("${p#"$HOME"/}"); fi
done

# What the tar step leaves out (the estimate below applies the same two rules):
excl=(--exclude 'brain/*/node_modules')
if [ "$mode" = rehearsal ]; then excl+=(--exclude '.wacli/session.db*'); fi

# The gateway env file is needed by the dry run below as much as by the real backup.
envfile="$HOME/.openclaw/service-env/ai.openclaw.gateway.env"
set -a
# shellcheck source=/dev/null
. "$envfile"
set +a

# The live VM's disk is nearly full and a rehearsal export runs next to a busy gateway, so the check must
# not refuse an export that fits: it counts what is actually archived. That is the backup's own plan
# (`backup create --dry-run --json`: the included assets minus what it skips as regenerable or volatile,
# e.g. plugin node_modules; "covered" entries are inside an included asset and stay counted) plus the
# file-state items under the tar's excludes. Sizes are uncompressed disk usage, an upper bound for the
# compressed archives. 1 GiB margin on top.
kb_of() { { du -sk "$@" 2>/dev/null || true; } | awk '{ s += $1 } END { print s + 0 }'; }
files_kb_pruning() { # files_kb_pruning <dir> <find-expression-to-leave-out...>
  local d="$1"; shift
  { find "$d" \( "$@" \) -prune -o -type f -exec du -k {} + 2>/dev/null || true; } | awk '{ s += $1 } END { print s + 0 }'
}
estimate_kb() {
  local plan lines kind p it total=0
  plan=$(openclaw backup create --dry-run --json) || { echo "export: cannot plan the backup (openclaw backup create --dry-run failed)" >&2; return 1; }
  lines=$(node -e '
    const p = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const skip = (p.skipped || []).filter((s) => s.reason !== "covered").map((s) => s.sourcePath).sort((a, b) => a.length - b.length);
    const kept = [];
    for (const s of skip) if (!kept.some((k) => s === k || s.startsWith(k + "/"))) kept.push(s);
    for (const a of p.assets || []) console.log("include\t" + a.sourcePath);
    for (const s of kept) console.log("skip\t" + s);
  ' <<<"$plan") || { echo "export: cannot read the backup plan" >&2; return 1; }
  while IFS=$'\t' read -r kind p; do
    [ -n "$kind" ] || continue
    if [ "$kind" = include ]; then total=$((total + $(kb_of "$p"))); else total=$((total - $(kb_of "$p"))); fi
  done <<<"$lines"
  for it in "${items[@]}"; do
    p="$HOME/$it"
    [ -e "$p" ] || continue
    case "$it" in
      brain) total=$((total + $(files_kb_pruning "$p" -name node_modules))) ;;
      .wacli) if [ "$mode" = rehearsal ]; then total=$((total + $(files_kb_pruning "$p" -name 'session.db*'))); else total=$((total + $(kb_of "$p"))); fi ;;
      *) total=$((total + $(kb_of "$p"))) ;;
    esac
  done
  echo "$total"
}
if [ "${CLAW_EXPORT_SKIP_SPACE_CHECK:-0}" = 1 ]; then
  echo "export: WARNING: free-space check skipped (CLAW_EXPORT_SKIP_SPACE_CHECK=1); the export may fill the disk" >&2
else
  est_kb=$(estimate_kb)
  avail_kb=$(df -Pk "$HOME" | awk 'NR == 2 { print $4 }')
  if [ "${avail_kb:-0}" -lt $((est_kb + 1048576)) ]; then
    echo "export: not enough free space in $HOME: estimated export size $((est_kb / 1024)) MiB + 1024 MiB margin = $(((est_kb + 1048576) / 1024)) MiB needed, $((${avail_kb:-0} / 1024)) MiB free (CLAW_EXPORT_SKIP_SPACE_CHECK=1 skips this check)" >&2
    exit 1
  fi
fi

ts=$(date -u +%Y%m%dT%H%M%SZ)
out="$HOME/claw-export-$mode-$ts"
mkdir -m 700 "$out"
finished=0
cleanup() {
  [ "$finished" = 1 ] && return
  rm -rf "$out"
  echo "export: failed; removed the incomplete $out" >&2
  [ "$mode" = final ] && echo "export: check launchctl list; restart the guard and gateway if they were stopped" >&2
  return 0
}
trap cleanup EXIT

if [ "$mode" = final ]; then
  guard="gui/$(id -u)/local.openclaw-listener-guard"
  launchctl bootout "$guard" 2>/dev/null || true
  # A guard that is still loaded would restart the gateway we are about to stop: prove the bootout took.
  if launchctl print "$guard" >/dev/null 2>&1; then
    echo "export: the listener guard is still loaded after bootout; not stopping the gateway under it" >&2
    exit 1
  fi
  launchctl bootout "gui/$(id -u)/ai.openclaw.gateway"
  echo "gateway stopped"
fi

openclaw backup create --output "$out" --verify
shopt -s nullglob
backups=("$out"/*-openclaw-backup.tar.gz)
shopt -u nullglob
[ "${#backups[@]}" -eq 1 ] || { echo "export: expected one backup archive in $out, found ${#backups[@]}" >&2; exit 1; }
mv "${backups[0]}" "$out/openclaw-backup.tar.gz"

# No AppleDouble (._*) companion files: the archive is unpacked by GNU tar on Linux.
COPYFILE_DISABLE=1 tar -C "$HOME" -czf "$out/filestate.tar.gz" "${excl[@]}" "${items[@]}"

(cd "$out" && { echo "mode=$mode"; shasum -a 256 openclaw-backup.tar.gz filestate.tar.gz; } > MANIFEST)
chmod 600 "$out"/*
finished=1
du -sh "$out"
cat "$out/MANIFEST"
