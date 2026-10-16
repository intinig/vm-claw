#!/bin/bash
# Guest provisioning. Run as root from /opt/vm-claw/provision (host/claw.sh provision deploys it). Safe to re-run.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=provision/lib.sh
. "$here/lib.sh"
# shellcheck source=provision/vercmp.sh
. "$here/vercmp.sh"
# shellcheck source=provision/versions.env
. "$here/versions.env"
# shellcheck source=provision/bot.sh
. "$here/bot.sh"
U="admin"
H=/Users/admin

# --- user and home -----------------------------------------------------------
step "home at $H" \
  "[ \"\$(getent passwd $U | cut -d: -f6)\" = $H ] && [ -d $H ]" \
  "mkdir -p /Users && usermod -d $H -m $U"
step "timezone UTC" "[ \"\$(timedatectl show -p Timezone --value)\" = UTC ]" "timedatectl set-timezone UTC"

# --- base packages -------------------------------------------------------------
step "apt index fresh" "find /var/lib/apt/lists -name '*Packages*' -mmin -1440 | grep -q ." "apt-get update"
# python3: migrate/state-paths.py (a cross-home import, rehome.sh verify) and tests/isolation-check.sh need it.
apt_ensure ca-certificates curl gnupg git jq sqlite3 rsync zip unzip poppler-utils nftables unattended-upgrades python3

# --- security updates only ------------------------------------------------------
step "unattended-upgrades enabled" \
  "grep -q 'APT::Periodic::Unattended-Upgrade \"1\"' /etc/apt/apt.conf.d/20auto-upgrades" \
  "printf 'APT::Periodic::Update-Package-Lists \"1\";\nAPT::Periodic::Unattended-Upgrade \"1\";\n' > /etc/apt/apt.conf.d/20auto-upgrades"

# Debian's stock origins also allow point-release updates (label=Debian). Clear the list and
# keep only the security pocket. apt.conf.d is read in order, so 51 overrides 50unattended-upgrades.
step "unattended-upgrades security only" \
  "grep -qF '#clear Unattended-Upgrade::Origins-Pattern;' /etc/apt/apt.conf.d/51claw-security-only && grep -qF 'Origins-Pattern { \"origin=Debian,codename=\${distro_codename}-security,label=Debian-Security\"; };' /etc/apt/apt.conf.d/51claw-security-only" \
  "printf '#clear Unattended-Upgrade::Origins-Pattern;\nUnattended-Upgrade::Origins-Pattern { \"origin=Debian,codename=\${distro_codename}-security,label=Debian-Security\"; };\n' > /etc/apt/apt.conf.d/51claw-security-only"

# --- sshd: keys only -------------------------------------------------------------
step "sshd key-only" \
  "[ -f /etc/ssh/sshd_config.d/10-claw.conf ]" \
  "printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/10-claw.conf && systemctl reload ssh"

# --- egress firewall ---------------------------------------------------------------
gws=$(infra_addrs /run/systemd/resolve/resolv.conf /etc/resolv.conf)
[ -n "$gws" ] || { echo "FAILED  nftables egress policy (no IPv4 gateway or DNS address found; refusing to render an empty lima_gw set)"; exit 1; }
# Apply renders to a temp file and validates it (nft -c) before it replaces /etc/nftables.conf,
# so a bad render never lands behind the enabled unit (next boot would have no egress policy).
step "nftables egress policy" \
  "diff <(sed 's/@GW@/$gws/' $here/nftables.conf.tmpl) /etc/nftables.conf && systemctl is-enabled nftables && nft list table inet claw" \
  "tmp=\$(mktemp) && trap 'rm -f \"\$tmp\"' EXIT && sed 's/@GW@/$gws/' $here/nftables.conf.tmpl > \"\$tmp\" && nft -c -f \"\$tmp\" && install -m 0644 \"\$tmp\" /etc/nftables.conf && systemctl enable nftables && nft -f /etc/nftables.conf"

# --- apt repos: node (NodeSource), 1Password CLI, Tailscale ------------------------------
step "apt keyrings dir" "[ -d /etc/apt/keyrings ]" "install -d -m 755 /etc/apt/keyrings"
# Each check proves the repo is in the apt index (apt-cache policy names its URL), not just that
# its list file exists: the list is written before `apt-get update`, so a failed update would
# otherwise leave a file that makes the step pass forever. The greps are deliberately not -q:
# policy output is long, and under pipefail a grep that quits at its first match SIGPIPEs
# apt-cache (status 141), which would fail a check that matched.
step "nodesource repo" "apt-cache policy nodejs | grep -F deb.nodesource.com/node_${NODE_MAJOR}.x" \
  "curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg && echo 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main' > /etc/apt/sources.list.d/nodesource.list && apt-get update"
step "1password repo" "apt-cache policy 1password-cli | grep -F downloads.1password.com/linux/debian/arm64" \
  "curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor --yes -o /usr/share/keyrings/1password-archive-keyring.gpg && echo 'deb [arch=arm64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/arm64 stable main' > /etc/apt/sources.list.d/1password.list && apt-get update"
step "tailscale repo" "apt-cache policy tailscale | grep -F pkgs.tailscale.com/stable/debian" \
  "curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg && curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list && apt-get update"
apt_ensure nodejs 1password-cli tailscale chromium gh
# The agent's image and media tooling (system packages, never inside the OpenClaw install): Pillow and numpy for
# python3, ImageMagick (Debian's restrictive policy.xml), SVG to PNG, ffmpeg, and fonts for lettering.
apt_ensure python3-pil python3-numpy imagemagick librsvg2-bin ffmpeg fonts-liberation fonts-dejavu-extra fonts-comic-neue
# Fails closed on a wrong major (e.g. Debian's own nodejs 20 when the NodeSource index is missing);
# the apply upgrades to the NodeSource candidate, and if the repo is not in use the check still fails.
step "node $NODE_MAJOR" "node --version | grep -q \"^v${NODE_MAJOR}\.\"" \
  "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs"

# --- pinned release binaries -------------------------------------------------------------
# A subshell body with its own set -e/pipefail and an EXIT trap: a bad checksum, a cut-off
# download or a missing binary aborts before anything lands in /usr/local/bin, and the temp dir
# never leaks. <version> only labels the step; the url pins it.
install_tarball() (  # install_tarball <name> <version> <url> <sha256>
  set -euo pipefail
  name="$1" url="$3" sum="$4"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "$url" -o "$tmp/pkg.tgz"
  echo "$sum  $tmp/pkg.tgz" | sha256sum -c -
  tar -xzf "$tmp/pkg.tgz" -C "$tmp"
  install -m 755 "$(find "$tmp" -type f -name "$name" | head -1)" "/usr/local/bin/$name"
)
export -f install_tarball
step "wacli $WACLI_VERSION" "/usr/local/bin/wacli --version | grep -qF $WACLI_VERSION" \
  "install_tarball wacli $WACLI_VERSION $WACLI_URL $WACLI_SHA256"
step "sag $SAG_VERSION" "/usr/local/bin/sag --version 2>&1 | grep -qF $SAG_VERSION" \
  "install_tarball sag $SAG_VERSION $SAG_URL $SAG_SHA256"

# --- npm globals ---------------------------------------------------------------------
# npm 11 treats --allow-scripts as advisory: a package it does not name still runs its install
# script, with a notice. --strict-allow-scripts turns an unnamed one into a hard error
# (ESTRICTALLOWSCRIPTS, nothing installed), so each install names exactly the packages whose
# scripts it needs (the set npm listed for these pinned versions) and anything new fails loudly.
# Scoped to the command: no npm config is changed.
#   openclaw: package lifecycle cleanup + fs-safe prebuild repair   esbuild: links the native binary
#   koffi: prebuilt-binding install step   protobufjs, @google/genai: version check / no-op
OPENCLAW_ALLOW_SCRIPTS="openclaw,esbuild,koffi,protobufjs,@google/genai"
SUMMARIZE_ALLOW_SCRIPTS="protobufjs,@google/genai"
# The pin is a floor, never a ceiling: `openclaw update` moves the CLI (and migrates its state databases) past
# it, and a re-provision must not take a running gateway back down. Install only when the CLI is absent or
# older than the pin; a newer one is left alone, with a notice.
export -f vercmp version_ge openclaw_installed_version
oc_have=$(openclaw_installed_version || true)
if [ -n "$oc_have" ] && [ "$(vercmp "$oc_have" "$OPENCLAW_VERSION" || true)" = gt ]; then
  echo "notice  openclaw: installed $oc_have is newer than the pin $OPENCLAW_VERSION; not downgrading; bump OPENCLAW_VERSION in provision/versions.env"
fi
step "openclaw >= $OPENCLAW_VERSION" "version_ge \"\$(openclaw_installed_version)\" $OPENCLAW_VERSION" \
  "npm install -g --strict-allow-scripts --allow-scripts=$OPENCLAW_ALLOW_SCRIPTS openclaw@$OPENCLAW_VERSION"
if [ -n "${SUMMARIZE_SPEC:-}" ]; then
  step "summarize" "npm ls -g --depth=0 | grep -qF \"$SUMMARIZE_SPEC\"" \
    "npm install -g --strict-allow-scripts --allow-scripts=$SUMMARIZE_ALLOW_SCRIPTS $SUMMARIZE_SPEC"
fi

# --- compat links: free-text references to Homebrew paths keep working -----------------------
# Structured config is rewritten to real paths (migrate/binpaths.mjs); these links only
# back up commands an agent reads in a prompt or note and runs literally.
for pair in node:/usr/bin/node op:/usr/bin/op wacli:/usr/local/bin/wacli sag:/usr/local/bin/sag openclaw:/usr/bin/openclaw; do
  n="${pair%%:*}"; t="${pair#*:}"
  step "compat /opt/homebrew/bin/$n" "[ \"\$(readlink /opt/homebrew/bin/$n)\" = $t ]" \
    "install -d /opt/homebrew/bin && ln -sfn $t /opt/homebrew/bin/$n"
done
step "compat node@24" "[ \"\$(readlink /opt/homebrew/opt/node@24/bin/node)\" = /usr/bin/node ]" \
  "install -d /opt/homebrew/opt/node@24/bin && ln -sfn /usr/bin/node /opt/homebrew/opt/node@24/bin/node"

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
export -f install_sshd_dropin
# sshd -T prints the effective config; plain grep (not -q) so a long producer is never cut off by SIGPIPE.
step "sshd denies $BOT_USER" "sshd -T | grep -ix 'denyusers $BOT_USER'" \
  "install_sshd_dropin /etc/ssh/sshd_config.d/20-claw-bot.conf 'DenyUsers $BOT_USER' && systemctl reload ssh"
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

summary
