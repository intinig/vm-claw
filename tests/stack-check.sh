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
# Test seams: the repo path and the account that must own it (root on a guest).
repo_path="${STACK_CHECK_REPO:-$CLAW_REPO}"; repo_owner="${STACK_CHECK_REPO_OWNER:-root}"
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
chk "xvfb (the browser's display)" "[ -x /usr/bin/Xvfb ]"
chk "gh"                         "gh --version"
# migrate/state-paths.py (a cross-home import and rehome.sh verify) needs it; provisioning installs it.
chk "python3 3.9+ with sqlite3 (the state-path migration)" "python3 -c 'import sqlite3, sys; sys.exit(sys.version_info < (3, 9))'"
for b in node op wacli sag openclaw; do chk "compat /opt/homebrew/bin/$b" "[ -x /opt/homebrew/bin/$b ]"; done
chk "compat node@24"             "[ -x /opt/homebrew/opt/node@24/bin/node ]"
# The bot account (spec 2026-10-02 §1). Its home is mode 700: what is inside is looked at through sudo, never as
# admin directly, where a refused look would read as "absent".
chk "bot $BOT_USER is $BOT_UID:$BOT_UID, $BOT_HOME, /bin/bash" "[ \"\$(getent passwd $BOT_USER | cut -d: -f3,4,6,7)\" = '$BOT_UID:$BOT_UID:$BOT_HOME:/bin/bash' ]"
chk "bot home mode 700, $BOT_USER's" "[ \"\$(sudo -n stat -c %a:%U:%G $BOT_HOME)\" = '700:$BOT_USER:$BOT_USER' ]"
chk "bot password locked"        "[ \"\$(sudo -n passwd -S $BOT_USER | cut -d' ' -f2)\" = L ]"
chk "bot in its own group only"  "[ \"\$(id -Gn $BOT_USER)\" = $BOT_USER ]"
chk "no sudo for $BOT_USER"      "out=\$(LC_ALL=C sudo -n -l -U $BOT_USER 2>&1 || true); grep -qF 'is not allowed to run sudo' <<<\"\$out\""
chk "no SSH login keys for $BOT_USER" "sudo -n test ! -e $BOT_HOME/.ssh/authorized_keys && sudo -n test ! -e $BOT_HOME/.ssh/authorized_keys2"
chk "sshd denies $BOT_USER"      "sudo -n sshd -T 2>/dev/null | grep -ix 'denyusers $BOT_USER'"
chk "linger $BOT_USER"           "loginctl show-user $BOT_USER -p Linger | grep -q yes"
chk "repo at $CLAW_REPO: root's, writable by no one else" \
  "[ -f $repo_path/DEPLOYED ] && [ -z \"\$(find $repo_path \\( ! -user $repo_owner -o -perm -0020 -o -perm -0002 \\) -print | head -1)\" ]"
ts_state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true)
if [ "$ts_state" = Running ]; then
  chk "tailscale operator $BOT_USER" "[ \"\$(sudo -n tailscale debug prefs | jq -r '.OperatorUser // empty')\" = $BOT_USER ]"
else
  echo "skip tailscale operator (Tailscale is ${ts_state:-not running}; provisioning sets it after tailscale up)"
fi
[ "$fail" -eq 0 ] && echo "stack: OK"
exit "$fail"
