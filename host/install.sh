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
