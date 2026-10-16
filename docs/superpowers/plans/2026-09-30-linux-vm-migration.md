# vm-claw Linux Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move OpenClaw from the Tart macOS VM to a reproducible, isolated Lima + Debian 13 VM on the same host, losing nothing.

**Architecture:** `lima/claw.yaml` defines an isolated NAT-only VM with one port forward. `provision/provision.sh` builds the guest idempotently from pinned versions. `migrate/export.sh` (old VM) and `migrate/import.sh` (new VM) move state, with the guest home kept at `/Users/admin` so stored absolute paths stay valid. Only binary paths in structured config are rewritten. Nightly backups leave the VM by host pull plus restic.

**Tech Stack:** Lima 2.2 (`vz`), Debian 13 arm64, bash + shellcheck, Node 24 (`node:test`), systemd user units, nftables, launchd (host), restic.

**Spec:** `docs/superpowers/specs/2026-09-30-linux-vm-migration-design.md`

## Global Constraints

- The repo is public: never commit secrets, IPs, phone numbers, WhatsApp JIDs, account names, job IDs or key fragments. Scripts find things by pattern, not by hard-coded identifier.
- Guest user `admin`, home is a real directory at `/Users/admin`. Repo scripts use `$HOME`, never a literal `/home` or `/Users`.
- Guest timezone `UTC` (matches the old guest; Lima defaults to the host's).
- Pinned versions: OpenClaw `2026.9.7`, node major `24`, wacli `0.13.0`, sag `0.3.0`. No upgrades during the move.
- Isolation: `mounts: []`; exactly one port forward (guest `127.0.0.1:18789` → host `127.0.0.1:18789`); NAT only; guest egress to RFC1918/link-local dropped except DNS and DHCP to Lima's gateway.
- Never run two gateways with the same WhatsApp credentials. Rehearsal imports exclude them and disable cron.
- The old Tart VM stays stopped, not deleted, for 14 days after cutover.
- Operator parameters, supplied at run time and never committed: `<host>` = the appliance's SSH target; `<router-ip>` = any address on the home LAN (the router is simplest), used only to prove the guest cannot reach the LAN.
- Machines: **old VM** = the Tart guest (macOS, `admin`); **host** = the Mac mini appliance (macOS 27, runs both VMs); **dev Mac** = where the rehearsal runs (36 GB RAM, Lima 2.2.0 already installed). The host has 16 GB; the Tart VM uses 8 GiB, so the rehearsal cannot run on the host.

## Review Focus

1. **Importing a rehearsal export as final, or vice versa, or restoring a real backup for a drill.** A rehearsal archive lacks WhatsApp credentials; importing it as `final` would start a gateway with no links, and a drill that kept real credentials would put a second gateway on the bot's WhatsApp devices. Expected: `import.sh final` refuses `mode=rehearsal`; `import.sh rehearsal` refuses an archive containing WhatsApp credentials; `import.sh drill` accepts anything but strips both credential sets and disables cron before starting. Tests in Task 7.
2. **Re-running `import.sh` on a guest that already has state.** Expected: refuse unless `--force`, and with `--force` move the existing `~/.openclaw` aside rather than overwrite it. Test in Task 7.
3. **A truncated or corrupted transfer.** Expected: import verifies every manifest checksum before touching `$HOME`. Test in Task 7.
4. **A new service in the guest listening on a port.** Expected: not reachable from the host; Lima's catch-all forward must be neutralised. Probe in Task 2's isolation check.
5. **The listener guard on Linux paths.** Expected: identical decisions to the macOS guard on the same log lines, and a restart through `systemctl --user`. Replay tests in Task 6.

---

## File Structure

```
Makefile                                 lint (shellcheck) + unit (node --test)
lima/claw.yaml                           VM definition
host/claw.sh                             host wrapper: create | provision | start | stop | shell | destroy
host/pull-backups.sh                     host: pull newest guest backup, restic off-site
host/local.vm-claw.pull-backups.plist    host launchd schedule for pull-backups.sh
provision/lib.sh                         step helpers + change counter
provision/versions.env                   pinned versions and release checksums
provision/nftables.conf.tmpl             egress firewall template
provision/provision.sh                   guest provisioning (root), idempotent
migrate/export.sh                        old VM: backup + file-state + manifest
migrate/import.sh                        new VM: verify, restore, rewrite, gate, start
migrate/binpaths.mjs                     binary-path rewrite (pure functions + CLI)
migrate/binpaths.test.mjs
migrate/scan-refs.mjs                    free-text scan for /opt/homebrew/bin + macOS-only commands
migrate/scan-refs.test.mjs
ops/listener-guard/guard.mjs             stranded-listener guard (pure core + CLI)
ops/listener-guard/guard.test.mjs
ops/listener-guard/openclaw-listener-guard.service
ops/listener-guard/openclaw-listener-guard.timer
ops/backup/nightly-backup.sh             guest nightly backup
ops/backup/openclaw-nightly-backup.service
ops/backup/openclaw-nightly-backup.timer
tests/isolation-check.sh                 host-side: mounts, forwards, no LAN address
tests/firewall-check.sh                  guest-side: LAN blocked, internet + DNS OK
tests/acceptance.sh                      guest-side automatable acceptance items
docs/verification.md                     facts established in Task 1
README.md                                runbook (rewritten in Task 12)
CLAUDE.md                                agent guidance (rewritten in Task 12)
```

---

### Task 1: Scaffolding, pinned versions, verified facts

**Files:**
- Create: `Makefile`, `provision/versions.env`, `docs/verification.md`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `make lint`, `make unit`, `make test`. `provision/versions.env` keys: `OPENCLAW_VERSION`, `NODE_MAJOR`, `WACLI_VERSION`, `WACLI_URL`, `WACLI_SHA256`, `SAG_VERSION`, `SAG_URL`, `SAG_SHA256`, `SUMMARIZE_SPEC`.

- [ ] **Step 1: Write the Makefile**

```make
SHELL := /bin/bash
# find, not git ls-files: new files must be linted and tested before their first commit.
SH_FILES = $(shell find . -name '*.sh' -not -path './.git/*')
TEST_FILES = $(shell find migrate ops -name '*.test.mjs' 2>/dev/null)

.PHONY: lint unit test
lint:
	@if [ -n "$(SH_FILES)" ]; then shellcheck -x $(SH_FILES); else echo "lint: no shell files yet"; fi

unit:
	@if [ -n "$(TEST_FILES)" ]; then node --test $(TEST_FILES); else echo "unit: no tests yet"; fi

test: lint unit
```

- [ ] **Step 2: Extend `.gitignore`**

Append:

```
# Migration exports and backups carry credentials — never commit them
claw-export-*/
*.tar.gz
*.env.local
```

- [ ] **Step 3: Verify release artifacts exist for the pinned versions**

Run on the dev Mac:

```bash
for r in openclaw/wacli:v0.13.0 steipete/sag:v0.3.0; do
  gh release view --repo "${r%%:*}" "${r##*:}" --json assets --jq '.assets[].name' | grep linux_arm64 || echo "NO linux_arm64 for $r"
done
```

Expected: one `…_linux_arm64.tar.gz` line per tool. If a line reads `NO linux_arm64`, set that tool's URL in Step 5 to the source tag and add a build step to Task 4 Step 3 (`go build` of that tag; install `golang` with apt for it).

- [ ] **Step 4: Establish how `summarize` is distributed**

On the old VM:

```bash
brew info summarize | head -3; summarize --version
```

If the formula installs an npm package, record `SUMMARIZE_SPEC=<package>@<version>`. If it is a native macOS-only binary with no Linux build, record `SUMMARIZE_SPEC=` (empty); Task 4 skips it and `docs/verification.md` notes it as dropped.

- [ ] **Step 5: Write `provision/versions.env`**

Compute the checksums, then write the file:

```bash
for u in https://github.com/openclaw/wacli/releases/download/v0.13.0/wacli_0.13.0_linux_arm64.tar.gz \
         https://github.com/steipete/sag/releases/download/v0.3.0/sag_0.3.0_linux_arm64.tar.gz; do
  curl -fsSL "$u" | shasum -a 256 | awk -v u="$u" '{print $1, u}'
done
```

```sh
# Pinned to what the Tart guest runs on 2026-09-30. Upgrade one at a time, after cutover.
OPENCLAW_VERSION=2026.9.7
NODE_MAJOR=24
WACLI_VERSION=0.13.0
WACLI_URL=https://github.com/openclaw/wacli/releases/download/v0.13.0/wacli_0.13.0_linux_arm64.tar.gz
WACLI_SHA256=<first hash printed above>
SAG_VERSION=0.3.0
SAG_URL=https://github.com/steipete/sag/releases/download/v0.3.0/sag_0.3.0_linux_arm64.tar.gz
SAG_SHA256=<second hash printed above>
SUMMARIZE_SPEC=<from Step 4, possibly empty>
```

Replace each `<…>` with the value the preceding command printed; the file must contain no `<` when committed.

- [ ] **Step 6: Establish the OpenClaw facts the migration depends on**

On the old VM, restore the newest backup to a scratch directory and record its layout, and look up the config keys the import will use:

```bash
b=$(ls -t ~/backups/*-openclaw-backup.tar.gz | head -1)
t=$(mktemp -d)/restore
openclaw backup restore "$b" --target "$t" --json | head -40
find "$t" -maxdepth 6 -type d | head -20
openclaw config schema > /tmp/schema.json
node -e 'const s=require("/tmp/schema.json");const r=s.schema||s;console.log("cron keys:",Object.keys(r.properties.cron.properties||{}).join(","))'
openclaw config unset --help | head -5
rm -rf "$(dirname "$t")" /tmp/schema.json
```

Record in `docs/verification.md`: the path under the restore target where `.openclaw` lands (expected `payload/posix/Users/admin/.openclaw`), the config key that disables the cron scheduler (expected `cron.enabled`), and whether `openclaw config unset` exists. If the scheduler has no disable key, record the fallback: rehearsal import runs `openclaw automations disable` for every enabled job instead (Task 7 handles both).

- [ ] **Step 7: Write `docs/verification.md`**

```markdown
# Verified facts (2026-09-30)

| Fact | Result | Consequence |
|---|---|---|
| wacli 0.13.0 linux-arm64 release | <yes/no> | <tarball / build from source> |
| sag 0.3.0 linux-arm64 release | <yes/no> | <tarball / build from source> |
| summarize distribution | <npm spec / none> | <installed / dropped> |
| backup restore layout | <path under --target> | import.sh copies from there |
| cron scheduler disable key | <key / none> | rehearsal disables via key / per-job |
| `openclaw config unset` | <yes/no> | iMessage channel removed via unset / set to {} |
| Host RAM / Tart VM RAM | 16 GB / 8 GiB | rehearsal on dev Mac; host pre-provisions at 4 GiB |
| Lima version | 2.2.0 | `limactl autostart` (start-at-login deprecated) |
```

Fill every `<…>` from Steps 3–6; no `<` remains when committed.

- [ ] **Step 8: Verify and commit**

Run: `make lint` and `make unit`. Expected: `lint: no shell files yet` and `unit: no tests yet`.

```bash
git add Makefile .gitignore provision/versions.env docs/verification.md
git commit -m "chore: scaffolding, pinned versions, verified migration facts"
```

---

### Task 2: Isolated VM definition and host wrapper

**Files:**
- Create: `lima/claw.yaml`, `host/claw.sh`, `tests/isolation-check.sh`

**Interfaces:**
- Consumes: `provision/versions.env` (not yet read; `claw.sh provision` is wired in Task 3).
- Produces: `host/claw.sh create [--memory GiB] | provision | start | stop | shell [cmd…] | destroy`; instance name `claw`; `tests/isolation-check.sh` exits non-zero on any violation.

- [ ] **Step 1: Write the failing isolation check**

`tests/isolation-check.sh`:

```bash
#!/bin/bash
# Host-side isolation check for the `claw` Lima instance. Exits 1 on any violation.
set -euo pipefail
inst="${1:-claw}"
fail=0
bad() { echo "FAIL: $*"; fail=1; }
g() { limactl shell "$inst" -- "$@"; }

# 1. No host filesystem mounted into the guest.
if g sh -c 'mount | grep -E "virtiofs|9p|sshfs|fuse\.sshfs"' >/dev/null 2>&1; then
  bad "guest has host mounts: $(g sh -c 'mount | grep -E "virtiofs|9p|sshfs"')"
fi

# 2. Only 18789 is forwarded. Open two probe listeners in the guest and try them from the host.
g sh -c 'nohup python3 -m http.server 18790 --bind 127.0.0.1 >/dev/null 2>&1 & nohup python3 -m http.server 18791 --bind 0.0.0.0 >/dev/null 2>&1 &'
sleep 5   # Lima's guest agent reports new listeners within ~1s; give it margin
for p in 18790 18791; do
  if nc -z -G 2 127.0.0.1 "$p" 2>/dev/null; then bad "guest port $p is forwarded to the host"; fi
done
g sh -c 'pkill -f "http.server 1879[01]"' || true

# 3. The guest has no address on the host's LAN.
lan_if=$(route -n get default | awk '/interface:/{print $2}')
lan_net=$(ipconfig getifaddr "$lan_if" | cut -d. -f1-3)
if g sh -c "ip -4 -o addr | grep -q ' ${lan_net}\.'"; then bad "guest has an address in the host LAN ${lan_net}.0/24"; fi

[ "$fail" -eq 0 ] && echo "isolation: OK"
exit "$fail"
```

- [ ] **Step 2: Write the host wrapper**

`host/claw.sh`:

```bash
#!/bin/bash
# Host-side wrapper around limactl for the `claw` instance.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
inst=claw

case "${1:-}" in
  create)
    mem=8; [ "${2:-}" = "--memory" ] && mem="$3"
    limactl create --name="$inst" --memory="$mem" --tty=false "$repo/lima/claw.yaml"
    ;;
  provision)
    limactl shell "$inst" -- sudo rm -rf /opt/claw-provision
    limactl copy -r "$repo/provision" "$inst:/tmp/claw-provision"
    limactl shell "$inst" -- sudo mv /tmp/claw-provision /opt/claw-provision
    limactl shell "$inst" -- sudo bash /opt/claw-provision/provision.sh
    ;;
  start)   limactl start "$inst" ;;
  stop)    limactl stop "$inst" ;;
  shell)   shift; limactl shell "$inst" -- "$@" ;;
  destroy) limactl delete --force "$inst" ;;
  *) echo "usage: $0 create [--memory GiB] | provision | start | stop | shell [cmd…] | destroy" >&2; exit 2 ;;
esac
```

- [ ] **Step 3: Write the VM definition**

`lima/claw.yaml`:

```yaml
# Isolated Debian 13 guest for OpenClaw. See docs/superpowers/specs/2026-09-30-linux-vm-migration-design.md
minimumLimaVersion: 2.0.0

# Only the image. The stock `debian-13` template also pulls in
# `_default/mounts`, which mounts the host home directory — never include it.
base:
- template:_images/debian-13

vmType: vz
cpus: 4
memory: 8GiB
disk: 100GiB
timezone: UTC

user:
  name: admin
  # Same absolute home as the old macOS guest, so the ~61k absolute paths in
  # OpenClaw's state databases stay valid without rewriting them.
  home: /Users/admin

mounts: []
containerd:
  system: false
  user: false

ssh:
  loadDotSSHPubKeys: false
  forwardAgent: false

portForwards:
# The gateway, for the appliance face app. Nothing else leaves the guest.
- guestIP: 127.0.0.1
  guestPort: 18789
  hostIP: 127.0.0.1
  hostPort: 18789
# Neutralise Lima's built-in catch-all forward of every guest port.
- guestIP: 127.0.0.1
  proto: any
  ignore: true
- guestIP: 0.0.0.0
  proto: any
  ignore: true
```

- [ ] **Step 4: Create the instance on the dev Mac and run the check**

```bash
chmod +x host/claw.sh tests/isolation-check.sh
host/claw.sh create --memory 8
host/claw.sh start
host/claw.sh shell -- sh -c 'echo $HOME; id; date +%Z'
tests/isolation-check.sh
```

Expected: `/Users/admin`, `uid=… (admin)`, `UTC`, then `isolation: OK`. If `$HOME` is not `/Users/admin` (cloud-init could not create `/Users`), Task 3's `ensure_home` step fixes it; note it and continue. If any `FAIL` line appears, fix `claw.yaml` before continuing — do not proceed with a leaking VM.

- [ ] **Step 5: Prove the check can fail**

Temporarily delete the two `ignore: true` rules, `host/claw.sh destroy && host/claw.sh create && host/claw.sh start`, run `tests/isolation-check.sh`. Expected: `FAIL: guest port 18790 is forwarded to the host`. Restore the rules, recreate, re-run: `isolation: OK`.

- [ ] **Step 6: Lint and commit**

```bash
make lint
git add lima/claw.yaml host/claw.sh tests/isolation-check.sh
git commit -m "feat: isolated Lima VM definition, host wrapper, isolation check"
```

---

### Task 3: Provisioning — base system, firewall, idempotency

**Files:**
- Create: `provision/lib.sh`, `provision/provision.sh`, `provision/nftables.conf.tmpl`, `tests/firewall-check.sh`

**Interfaces:**
- Consumes: `provision/versions.env`.
- Produces: `provision.sh` prints `provision: changed=<n> ok=<m>` as its last line; helpers `step <name> <check-cmd> <apply-cmd>`, `apt_ensure <pkg…>`.

- [ ] **Step 1: Write the helpers**

`provision/lib.sh`:

```bash
#!/bin/bash
# Idempotent step helpers. A step runs its check first and only applies on failure.
CHANGED=0; OK=0

step() {  # step <name> <check-command> <apply-command>
  local name="$1" check="$2" apply="$3"
  if bash -c "$check" >/dev/null 2>&1; then OK=$((OK+1)); echo "ok      $name"; return; fi
  echo "change  $name"
  bash -c "$apply"
  bash -c "$check" >/dev/null 2>&1 || { echo "FAILED  $name (check still fails after apply)"; exit 1; }
  CHANGED=$((CHANGED+1))
}

apt_ensure() {  # apt_ensure pkg...
  local missing=()
  for p in "$@"; do dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p"); done
  if [ "${#missing[@]}" -eq 0 ]; then OK=$((OK+1)); echo "ok      apt: $*"; return; fi
  echo "change  apt: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
  CHANGED=$((CHANGED+1))
}

summary() { echo "provision: changed=$CHANGED ok=$OK"; }
```

- [ ] **Step 2: Write the firewall template**

`provision/nftables.conf.tmpl` (`@GW@` is replaced with Lima's gateway/DNS addresses at provision time):

```
#!/usr/sbin/nft -f
# Egress policy: the guest may reach the internet and the tailnet, never the host LAN.
flush ruleset
table inet claw {
  set lima_gw { type ipv4_addr; elements = { @GW@ } }
  chain output {
    type filter hook output priority 0; policy accept;
    oifname "lo" accept
    ct state established,related accept
    meta l4proto ipv6-icmp accept
    ip daddr @lima_gw udp dport { 53, 67 } accept
    ip daddr @lima_gw tcp dport 53 accept
    ip daddr 100.64.0.0/10 accept
    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 } counter drop
    ip6 daddr { fc00::/7, fe80::/10 } counter drop
  }
}
```

- [ ] **Step 3: Write the failing firewall check**

`tests/firewall-check.sh` (runs inside the guest; the LAN address is passed in so no private IP is committed):

```bash
#!/bin/bash
# Guest-side egress check. Usage: firewall-check.sh <a LAN address, e.g. the home router>
set -euo pipefail
lan="${1:?usage: $0 <lan-ip>}"
fail=0
# Any open TCP port counts as reachable; routers usually answer on 53, 80 or 443.
for port in 53 80 443; do
  if timeout 4 bash -c "exec 3<>/dev/tcp/$lan/$port" 2>/dev/null; then echo "FAIL: LAN address $lan reachable on $port"; fail=1; break; fi
done
curl -s -m 15 -o /dev/null https://deb.debian.org/ || { echo "FAIL: internet unreachable"; fail=1; }
getent hosts github.com >/dev/null || { echo "FAIL: DNS broken"; fail=1; }
[ "$fail" -eq 0 ] && echo "firewall: OK"
exit "$fail"
```

Run it before provisioning (Task 2's VM has no firewall yet): `host/claw.sh shell -- bash -s <router-ip> < tests/firewall-check.sh`. Expected: `FAIL: LAN address … reachable on <port>`. If it instead prints `firewall: OK`, the probe cannot see the router: pick a `<router-ip>` that answers on one of those ports from the dev Mac (`nc -z <ip> 80`) — a check that cannot fail proves nothing.

- [ ] **Step 4: Write the base of `provision.sh`**

`provision/provision.sh`:

```bash
#!/bin/bash
# Guest provisioning. Run as root from /opt/claw-provision. Safe to re-run.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=provision/lib.sh
. "$here/lib.sh"
# shellcheck source=provision/versions.env
. "$here/versions.env"
U=admin
H=/Users/admin

# --- user and home -----------------------------------------------------------
step "home at $H" \
  "[ \"\$(getent passwd $U | cut -d: -f6)\" = $H ] && [ -d $H ]" \
  "mkdir -p /Users && usermod -d $H -m $U"
step "timezone UTC" "[ \"\$(timedatectl show -p Timezone --value)\" = UTC ]" "timedatectl set-timezone UTC"

# --- base packages -------------------------------------------------------------
step "apt index fresh" "find /var/lib/apt/lists -name '*Packages*' -mmin -1440 | grep -q ." "apt-get update"
apt_ensure ca-certificates curl gnupg git jq sqlite3 rsync zip unzip poppler-utils nftables unattended-upgrades python3

# --- security updates only ------------------------------------------------------
step "unattended-upgrades enabled" \
  "grep -q 'APT::Periodic::Unattended-Upgrade \"1\"' /etc/apt/apt.conf.d/20auto-upgrades" \
  "printf 'APT::Periodic::Update-Package-Lists \"1\";\nAPT::Periodic::Unattended-Upgrade \"1\";\n' > /etc/apt/apt.conf.d/20auto-upgrades"

# --- sshd: keys only -------------------------------------------------------------
step "sshd key-only" \
  "[ -f /etc/ssh/sshd_config.d/10-claw.conf ]" \
  "printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/10-claw.conf && systemctl reload ssh"

# --- egress firewall ---------------------------------------------------------------
gw=$(awk '/^nameserver/{print $2}' /etc/resolv.conf | grep -E '^[0-9.]+$' | paste -sd, -)
dgw=$(ip -4 route show default | awk '{print $3; exit}')
gws=$(printf '%s,%s' "$dgw" "$gw" | tr ',' '\n' | grep -v '^127\.' | sort -u | paste -sd, - | sed 's/,/, /g')
# Exported before the step: the apply command runs in a child bash.
export rules; rules=$(sed "s/@GW@/$gws/" "$here/nftables.conf.tmpl")
step "nftables egress policy" \
  "diff <(printf '%s\n' \"\$(sed 's/@GW@/$gws/' $here/nftables.conf.tmpl)\") /etc/nftables.conf && systemctl is-enabled nftables && nft list table inet claw" \
  "printf '%s\n' \"\$rules\" > /etc/nftables.conf && systemctl enable nftables && nft -f /etc/nftables.conf"

summary
```

Note on the firewall step: the check re-renders the template to compare, so a template change is applied on the next run.

- [ ] **Step 5: Wire `claw.sh provision` and run it**

`host/claw.sh provision` already copies `provision/` and runs it. Run:

```bash
host/claw.sh provision
host/claw.sh shell -- bash -s <router-ip> < tests/firewall-check.sh
```

Expected: last provisioning line `provision: changed=<n> ok=<m>` with n>0; then `firewall: OK`.

- [ ] **Step 6: Prove idempotency**

Run `host/claw.sh provision` again. Expected last line: `provision: changed=0 ok=<m>`. Any `change` line on the second run is a bug in that step's check — fix the check, not the counter.

- [ ] **Step 7: Lint and commit**

```bash
make lint
git add provision/lib.sh provision/provision.sh provision/nftables.conf.tmpl tests/firewall-check.sh
git commit -m "feat(provision): base system, egress firewall, idempotent steps"
```

---

### Task 4: Provisioning — the OpenClaw stack

**Files:**
- Modify: `provision/provision.sh` (append before `summary`)
- Create: `tests/stack-check.sh`

**Interfaces:**
- Consumes: `versions.env` keys from Task 1; `step`, `apt_ensure` from Task 3.
- Produces: `/usr/bin/node` (major 24), `/usr/bin/openclaw` (via npm global, `2026.9.7`), `/usr/bin/op`, `/usr/bin/tailscale`, `/usr/local/bin/wacli`, `/usr/local/bin/sag`, `/usr/bin/chromium`; compat symlinks `/opt/homebrew/bin/{node,op,wacli,sag,openclaw}`; `/opt/homebrew/opt/node@24/bin/node`; lingering for `admin`.

- [ ] **Step 1: Write the failing stack check**

`tests/stack-check.sh` (guest-side):

```bash
#!/bin/bash
# Guest-side: every pinned tool present at the pinned version, compat links in place.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=provision/versions.env
. "${VERSIONS_ENV:-$here/provision/versions.env}"
fail=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
chk "node $NODE_MAJOR"           "node --version | grep -q '^v$NODE_MAJOR\.'"
chk "openclaw $OPENCLAW_VERSION" "openclaw --version | grep -qF '$OPENCLAW_VERSION'"
chk "op"                         "op --version"
chk "tailscale"                  "tailscale version"
chk "wacli $WACLI_VERSION"       "wacli --version | grep -qF '$WACLI_VERSION'"
chk "sag $SAG_VERSION"           "sag --version 2>&1 | grep -qF '$SAG_VERSION'"
chk "chromium"                   "chromium --version"
chk "gh"                         "gh --version"
for b in node op wacli sag openclaw; do chk "compat /opt/homebrew/bin/$b" "[ -x /opt/homebrew/bin/$b ]"; done
chk "compat node@24"             "[ -x /opt/homebrew/opt/node@24/bin/node ]"
chk "linger admin"               "loginctl show-user admin -p Linger | grep -q yes"
[ "$fail" -eq 0 ] && echo "stack: OK"
exit "$fail"
```

Run: `limactl copy -r . claw:/tmp/vmclaw && host/claw.sh shell -- bash /tmp/vmclaw/tests/stack-check.sh`. Expected: several `FAIL` lines.

- [ ] **Step 2: Add the apt-repo tools**

Append to `provision.sh` before `summary`:

```bash
# --- node (NodeSource) ---------------------------------------------------------------
step "nodesource repo" "[ -f /etc/apt/sources.list.d/nodesource.list ]" \
  "curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && echo 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main' > /etc/apt/sources.list.d/nodesource.list && apt-get update"
# --- 1Password CLI -----------------------------------------------------------------
step "1password repo" "[ -f /etc/apt/sources.list.d/1password.list ]" \
  "curl -fsSL https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor -o /usr/share/keyrings/1password-archive-keyring.gpg && echo 'deb [arch=arm64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/arm64 stable main' > /etc/apt/sources.list.d/1password.list && apt-get update"
# --- Tailscale ---------------------------------------------------------------------
step "tailscale repo" "[ -f /etc/apt/sources.list.d/tailscale.list ]" \
  "curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg && curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list -o /etc/apt/sources.list.d/tailscale.list && apt-get update"
apt_ensure nodejs 1password-cli tailscale chromium gh
```

`install -d -m 755 /etc/apt/keyrings` must run first; add as the first line of this block:

```bash
step "apt keyrings dir" "[ -d /etc/apt/keyrings ]" "install -d -m 755 /etc/apt/keyrings"
```

- [ ] **Step 3: Add the pinned release tarballs and npm tools**

```bash
# --- pinned release binaries -------------------------------------------------------------
install_tarball() {  # install_tarball <name> <version> <url> <sha256>
  local name="$1" ver="$2" url="$3" sum="$4" tmp
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/pkg.tgz"
  echo "$sum  $tmp/pkg.tgz" | sha256sum -c -
  tar -xzf "$tmp/pkg.tgz" -C "$tmp"
  install -m 755 "$(find "$tmp" -type f -name "$name" | head -1)" "/usr/local/bin/$name"
  rm -rf "$tmp"
}
export -f install_tarball
step "wacli $WACLI_VERSION" "/usr/local/bin/wacli --version | grep -qF $WACLI_VERSION" \
  "install_tarball wacli $WACLI_VERSION $WACLI_URL $WACLI_SHA256"
step "sag $SAG_VERSION" "/usr/local/bin/sag --version 2>&1 | grep -qF $SAG_VERSION" \
  "install_tarball sag $SAG_VERSION $SAG_URL $SAG_SHA256"

# --- npm globals ---------------------------------------------------------------------
step "openclaw $OPENCLAW_VERSION" "openclaw --version | grep -qF $OPENCLAW_VERSION" \
  "npm install -g openclaw@$OPENCLAW_VERSION"
if [ -n "${SUMMARIZE_SPEC:-}" ]; then
  step "summarize" "npm ls -g --depth=0 | grep -qF \"${SUMMARIZE_SPEC%@*}\"" "npm install -g $SUMMARIZE_SPEC"
fi
```

- [ ] **Step 4: Add the compat symlinks and lingering**

```bash
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

# --- user services run without a login session --------------------------------------------
step "linger $U" "loginctl show-user $U -p Linger | grep -q yes" "loginctl enable-linger $U"
```

- [ ] **Step 5: Provision, check, prove idempotency**

```bash
host/claw.sh provision
limactl copy -r . claw:/tmp/vmclaw && host/claw.sh shell -- bash /tmp/vmclaw/tests/stack-check.sh
host/claw.sh provision | tail -1
```

Expected: `stack: OK`, and the second provisioning ends `provision: changed=0 …`.

- [ ] **Step 6: Lint and commit**

```bash
make lint
git add provision/provision.sh tests/stack-check.sh
git commit -m "feat(provision): pinned OpenClaw stack, compat links, lingering"
```

---

### Task 5: Binary-path rewrite and free-text scan

**Files:**
- Create: `migrate/binpaths.mjs`, `migrate/binpaths.test.mjs`, `migrate/scan-refs.mjs`, `migrate/scan-refs.test.mjs`, `migrate/scan-allow.txt` (empty; one regex per line, added only for hits the rehearsal proves harmless — never with private identifiers)

**Interfaces:**
- Produces:
  - `DEFAULT_MAP: Record<string,string>` — `{"/opt/homebrew/bin/op":"/usr/bin/op","/opt/homebrew/bin/node":"/usr/bin/node","/opt/homebrew/opt/node@24/bin/node":"/usr/bin/node","/opt/homebrew/bin/wacli":"/usr/local/bin/wacli","/opt/homebrew/bin/sag":"/usr/local/bin/sag","/opt/homebrew/bin/openclaw":"/usr/bin/openclaw"}`
  - `rewriteOpenclawConfig(cfg: object, map) -> {cfg: object, changes: string[]}` — rewrites `secrets.providers.*.command` via the map, and replaces a `trustedDirs` entry `"/opt/homebrew"` with `"/usr/bin"`. Touches nothing else.
  - `rewriteHarvesterConfig(cfg: object, map) -> {cfg, changes}` — rewrites `wacliBin`.
  - `rewriteShellWrapper(text: string, map) -> {text, changes}` — replaces mapped absolute paths in a shell script.
  - `rewriteArgv(argv: string[], map) -> {argv, changed: boolean}` — for command automations.
  - CLI: `node migrate/binpaths.mjs <home>` rewrites `<home>/.openclaw/openclaw.json`, `<home>/brain/harvester/config.json`, `<home>/.openclaw/bin/op-nosym` in place (writing `*.pre-binpaths` backups) and prints each change.
  - `scan(text: string, allow: RegExp[]) -> {homebrew: string[], macos: string[]}` in `scan-refs.mjs`; CLI `node migrate/scan-refs.mjs <dir…>` exits 1 if any unmapped `/opt/homebrew/bin/<x>` or non-allow-listed macOS-only command is found.

- [ ] **Step 1: Write the failing tests**

`migrate/binpaths.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_MAP, rewriteOpenclawConfig, rewriteHarvesterConfig, rewriteShellWrapper, rewriteArgv } from "./binpaths.mjs";

const provider = (cmd) => ({ source: "exec", command: cmd, args: ["read", "op://Vault/Item/password"],
  passEnv: ["OP_SERVICE_ACCOUNT_TOKEN", "HOME"], trustedDirs: ["/Users/admin/.openclaw/bin", "/opt/homebrew"] });

test("rewrites trustedDirs /opt/homebrew to /usr/bin and leaves the wrapper command alone", () => {
  const cfg = { secrets: { providers: { a: provider("/Users/admin/.openclaw/bin/op-nosym"), f: { source: "file", path: "~/.openclaw/state/secrets.json" } } } };
  const { cfg: out, changes } = rewriteOpenclawConfig(structuredClone(cfg), DEFAULT_MAP);
  assert.deepEqual(out.secrets.providers.a.trustedDirs, ["/Users/admin/.openclaw/bin", "/usr/bin"]);
  assert.equal(out.secrets.providers.a.command, "/Users/admin/.openclaw/bin/op-nosym");
  assert.deepEqual(out.secrets.providers.f, cfg.secrets.providers.f);
  assert.equal(changes.length, 1);
});

test("rewrites a provider command that points straight at Homebrew", () => {
  const { cfg: out } = rewriteOpenclawConfig({ secrets: { providers: { a: provider("/opt/homebrew/bin/op") } } }, DEFAULT_MAP);
  assert.equal(out.secrets.providers.a.command, "/usr/bin/op");
});

test("never touches home paths or unrelated strings anywhere in the config", () => {
  const cfg = { agents: { defaults: { workspace: "/Users/admin/.openclaw/workspace" } }, note: "see /opt/homebrew/bin/wacli docs",
    secrets: { providers: { a: provider("/Users/admin/.openclaw/bin/op-nosym") } } };
  const { cfg: out } = rewriteOpenclawConfig(structuredClone(cfg), DEFAULT_MAP);
  assert.equal(out.agents.defaults.workspace, "/Users/admin/.openclaw/workspace");
  assert.equal(out.note, "see /opt/homebrew/bin/wacli docs");
});

test("is idempotent", () => {
  const once = rewriteOpenclawConfig({ secrets: { providers: { a: provider("/opt/homebrew/bin/op") } } }, DEFAULT_MAP).cfg;
  const twice = rewriteOpenclawConfig(structuredClone(once), DEFAULT_MAP);
  assert.deepEqual(twice.cfg, once);
  assert.equal(twice.changes.length, 0);
});

test("harvester wacliBin", () => {
  const { cfg, changes } = rewriteHarvesterConfig({ wacliBin: "/opt/homebrew/bin/wacli", storeDb: "/Users/admin/.wacli/wacli.db" }, DEFAULT_MAP);
  assert.equal(cfg.wacliBin, "/usr/local/bin/wacli");
  assert.equal(cfg.storeDb, "/Users/admin/.wacli/wacli.db");
  assert.equal(changes.length, 1);
});

test("shell wrapper: mapped paths replaced, everything else byte-identical", () => {
  const src = "#!/bin/sh\n# homebrew op is a symlink\n  /opt/homebrew/bin/op \"$@\"\n  sleep 2\n";
  const { text, changes } = rewriteShellWrapper(src, DEFAULT_MAP);
  assert.equal(text, "#!/bin/sh\n# homebrew op is a symlink\n  /usr/bin/op \"$@\"\n  sleep 2\n");
  assert.equal(changes.length, 1);
});

test("argv: only argv[0] is mapped", () => {
  assert.deepEqual(rewriteArgv(["/opt/homebrew/bin/node", "/Users/admin/brain/harvester/harvest.mjs"], DEFAULT_MAP),
    { argv: ["/usr/bin/node", "/Users/admin/brain/harvester/harvest.mjs"], changed: true });
  assert.deepEqual(rewriteArgv(["/usr/bin/node", "x"], DEFAULT_MAP), { argv: ["/usr/bin/node", "x"], changed: false });
});
```

`migrate/scan-refs.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { scan } from "./scan-refs.mjs";

test("finds Homebrew binary references", () => {
  assert.deepEqual(scan("run /opt/homebrew/bin/wacli sync now", []).homebrew, ["/opt/homebrew/bin/wacli"]);
});

test("finds macOS-only commands", () => {
  const r = scan("then launchctl kickstart -k gui/501/x and osascript -e 'x'", []);
  assert.deepEqual(r.macos.sort(), ["launchctl", "osascript"]);
});

test("allow-list suppresses a known-harmless mention", () => {
  assert.deepEqual(scan("historical: we used launchctl on the old VM", [/historical:.*launchctl/]).macos, []);
});

test("does not flag words that merely contain a command name", () => {
  assert.deepEqual(scan("reopened the openclaw docs", []).macos, []);
});
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make unit`. Expected: failures with `Cannot find module './binpaths.mjs'` and `./scan-refs.mjs`.

- [ ] **Step 3: Implement `migrate/binpaths.mjs`**

```js
#!/usr/bin/env node
// Rewrite Homebrew binary paths in OpenClaw's structured config to their Debian
// locations. Home paths are deliberately untouched: the guest keeps /Users/admin.
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

export const DEFAULT_MAP = {
  "/opt/homebrew/bin/op": "/usr/bin/op",
  "/opt/homebrew/bin/node": "/usr/bin/node",
  "/opt/homebrew/opt/node@24/bin/node": "/usr/bin/node",
  "/opt/homebrew/bin/wacli": "/usr/local/bin/wacli",
  "/opt/homebrew/bin/sag": "/usr/local/bin/sag",
  "/opt/homebrew/bin/openclaw": "/usr/bin/openclaw",
};

export function rewriteOpenclawConfig(cfg, map) {
  const changes = [];
  for (const [name, p] of Object.entries(cfg?.secrets?.providers ?? {})) {
    if (p?.source !== "exec") continue;
    if (map[p.command]) { changes.push(`secrets.providers.${name}.command: ${p.command} -> ${map[p.command]}`); p.command = map[p.command]; }
    if (Array.isArray(p.trustedDirs)) {
      p.trustedDirs = p.trustedDirs.map((d) => {
        if (d !== "/opt/homebrew") return d;
        changes.push(`secrets.providers.${name}.trustedDirs: /opt/homebrew -> /usr/bin`);
        return "/usr/bin";
      });
    }
  }
  return { cfg, changes };
}

export function rewriteHarvesterConfig(cfg, map) {
  const changes = [];
  if (map[cfg.wacliBin]) { changes.push(`wacliBin: ${cfg.wacliBin} -> ${map[cfg.wacliBin]}`); cfg.wacliBin = map[cfg.wacliBin]; }
  return { cfg, changes };
}

export function rewriteShellWrapper(text, map) {
  const changes = [];
  let out = text;
  for (const [from, to] of Object.entries(map)) {
    if (out.includes(from)) { out = out.split(from).join(to); changes.push(`${from} -> ${to}`); }
  }
  return { text: out, changes };
}

export function rewriteArgv(argv, map) {
  if (!map[argv[0]]) return { argv, changed: false };
  return { argv: [map[argv[0]], ...argv.slice(1)], changed: true };
}

function rewriteJsonFile(file, fn) {
  if (!fs.existsSync(file)) return [];
  const { cfg, changes } = fn(JSON.parse(fs.readFileSync(file, "utf8")), DEFAULT_MAP);
  if (changes.length) {
    fs.copyFileSync(file, `${file}.pre-binpaths`);
    fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
  }
  return changes.map((c) => `${path.basename(file)}: ${c}`);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const home = process.argv[2] ?? process.env.HOME;
  const out = [
    ...rewriteJsonFile(`${home}/.openclaw/openclaw.json`, rewriteOpenclawConfig),
    ...rewriteJsonFile(`${home}/brain/harvester/config.json`, rewriteHarvesterConfig),
  ];
  const wrapper = `${home}/.openclaw/bin/op-nosym`;
  if (fs.existsSync(wrapper)) {
    const { text, changes } = rewriteShellWrapper(fs.readFileSync(wrapper, "utf8"), DEFAULT_MAP);
    if (changes.length) { fs.copyFileSync(wrapper, `${wrapper}.pre-binpaths`); fs.writeFileSync(wrapper, text); }
    out.push(...changes.map((c) => `op-nosym: ${c}`));
  }
  for (const line of out) console.log(line);
  console.log(`binpaths: ${out.length} change(s)`);
}
```

- [ ] **Step 4: Implement `migrate/scan-refs.mjs`**

```js
#!/usr/bin/env node
// Scan free text (prompts, skills, notes, scripts) for things that break on Linux:
// Homebrew binary paths without a compat link, and macOS-only commands.
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { DEFAULT_MAP } from "./binpaths.mjs";

// Only names that are not also everyday words: "defaults", "security", "memo" would
// flag ordinary prose in prompts and fail the import for nothing.
const MACOS_ONLY = ["launchctl", "osascript", "pbcopy", "pbpaste", "scutil", "imsg"];

export function scan(text, allow) {
  const lines = text.split("\n").filter((l) => !allow.some((re) => re.test(l)));
  const body = lines.join("\n");
  const homebrew = [...new Set(body.match(/\/opt\/homebrew\/[\w@./-]*bin\/[\w.-]+/g) ?? [])];
  const macos = MACOS_ONLY.filter((c) => new RegExp(`(^|[\\s\`'"(;|&])${c}(\\s|$)`, "m").test(body));
  return { homebrew, macos };
}

function* files(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (!["node_modules", ".git", "vault"].includes(e.name)) yield* files(p); }
    else if (/\.(md|mjs|js|sh|json|txt)$/.test(e.name)) yield p;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const allowFile = process.env.SCAN_ALLOW ?? "";
  const allow = allowFile && fs.existsSync(allowFile)
    ? fs.readFileSync(allowFile, "utf8").split("\n").filter(Boolean).map((l) => new RegExp(l)) : [];
  let bad = 0;
  for (const dir of process.argv.slice(2)) {
    if (!fs.existsSync(dir)) continue;
    for (const f of files(dir)) {
      const { homebrew, macos } = scan(fs.readFileSync(f, "utf8"), allow);
      const unmapped = homebrew.filter((h) => !DEFAULT_MAP[h] && !fs.existsSync(h));
      if (unmapped.length || macos.length) { bad++; console.log(`${f}: homebrew=${unmapped.join(",")} macos=${macos.join(",")}`); }
    }
  }
  console.log(`scan-refs: ${bad} file(s) need attention`);
  process.exit(bad ? 1 : 0);
}
```

- [ ] **Step 5: Run the tests**

Run: `make unit`. Expected: all tests in both files pass.

- [ ] **Step 6: Prove the tests bite**

Change `"/usr/bin"` to `"/usr/local/bin"` in `rewriteOpenclawConfig`; `make unit` must fail the first test. Revert; `make unit` passes.

- [ ] **Step 7: Commit**

```bash
touch migrate/scan-allow.txt
git add migrate/binpaths.mjs migrate/binpaths.test.mjs migrate/scan-refs.mjs migrate/scan-refs.test.mjs migrate/scan-allow.txt
git commit -m "feat(migrate): binary-path rewrite and free-text scan with tests"
```

---

### Task 6: Listener guard for Linux

**Files:**
- Create: `ops/listener-guard/guard.mjs`, `ops/listener-guard/guard.test.mjs`, `ops/listener-guard/openclaw-listener-guard.service`, `ops/listener-guard/openclaw-listener-guard.timer`

**Interfaces:**
- Consumes: the macOS guard's rules (spec §2): signatures, ≥2 events in 10 min, ignore 5 min after `gateway ready` and 2 min after `Listening for WhatsApp inbound messages`, skip if WhatsApp not linked, 30 min cooldown, max 6/day.
- Produces: `decide({lines: string[], now: number, linked: boolean, restarts: number[]}) -> {action: "ok"|"skip"|"restart", reason: string, events: number}`; CLI `node guard.mjs [--dry-run] [--now ISO]` with env `GUARD_LOG_DIR` (default `/tmp/openclaw`), `GUARD_STATE` (default `~/.local/state/claw/listener-guard.json`), `GUARD_RESTART` (default `systemctl --user restart openclaw-gateway.service`; the unit name is confirmed in Task 7 Step 6 and set in the `.service` file).

- [ ] **Step 1: Write the failing tests**

`ops/listener-guard/guard.test.mjs`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { decide } from "./guard.mjs";

const T = (iso) => Date.parse(iso);
const line = (iso, msg) => JSON.stringify({ 1: msg, _meta: { date: iso } });
const base = [
  line("2026-09-30T08:00:00Z", "gateway ready"),
  line("2026-09-30T08:00:05Z", "Listening for WhatsApp inbound messages (DM + all groups)"),
];
const stranded = [
  line("2026-09-30T09:00:30Z", "Gateway client authority closed before dispatching cron.list"),
  line("2026-09-30T09:00:32Z", "The reply channel changed or cannot preserve its sender; delivery was not started."),
];

test("restarts on two signature events well after startup", () => {
  const r = decide({ lines: [...base, ...stranded], now: T("2026-09-30T09:02:00Z"), linked: true, restarts: [] });
  assert.equal(r.action, "restart");
  assert.equal(r.events, 2);
});

test("ignores startup noise inside the gateway-ready grace window", () => {
  const noise = [line("2026-09-30T08:02:00Z", "No active WhatsApp Web listener (account: default)"),
                 line("2026-09-30T08:02:30Z", "No active WhatsApp Web listener (account: default)")];
  assert.equal(decide({ lines: [...base, ...noise], now: T("2026-09-30T08:03:00Z"), linked: true, restarts: [] }).action, "ok");
});

test("one event is not enough", () => {
  assert.equal(decide({ lines: [...base, stranded[0]], now: T("2026-09-30T09:02:00Z"), linked: true, restarts: [] }).action, "ok");
});

test("skips when WhatsApp is not linked — a restart cannot help", () => {
  assert.equal(decide({ lines: [...base, ...stranded], now: T("2026-09-30T09:02:00Z"), linked: false, restarts: [] }).action, "skip");
});

test("respects the 30-minute cooldown", () => {
  const r = decide({ lines: [...base, ...stranded], now: T("2026-09-30T09:02:00Z"), linked: true, restarts: [T("2026-09-30T08:45:00Z")] });
  assert.equal(r.action, "skip");
  assert.match(r.reason, /cooldown/);
});

test("gives up after 6 restarts in 24h", () => {
  const six = [1, 2, 3, 4, 5, 6].map((h) => T("2026-09-30T00:00:00Z") + h * 3600e3 - 3600e3 * 0.5);
  const r = decide({ lines: [...base, ...stranded], now: T("2026-09-30T09:02:00Z"), linked: true, restarts: six });
  assert.equal(r.action, "skip");
  assert.match(r.reason, /6 restarts/);
});

test("ignores lines from the future when replaying history", () => {
  assert.equal(decide({ lines: [...base, ...stranded], now: T("2026-09-30T09:00:31Z"), linked: true, restarts: [] }).action, "ok");
});
```

- [ ] **Step 2: Run to verify failure**

Run: `make unit`. Expected: `Cannot find module './guard.mjs'`.

- [ ] **Step 3: Implement `ops/listener-guard/guard.mjs`**

```js
#!/usr/bin/env node
// Restarts the OpenClaw gateway when its WhatsApp listener is "stranded": the socket
// keeps receiving but replies/tools fail (OpenClaw 2026.9.x, after a config hot reload
// or a watchdog reconnect). Only a full gateway restart rebinds it.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, execSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const WINDOW_MS = 10 * 60e3;
const GRACE_READY_MS = 5 * 60e3;
const GRACE_LISTEN_MS = 2 * 60e3;
const MIN_EVENTS = 2;
const COOLDOWN_MS = 30 * 60e3;
const MAX_PER_DAY = 6;
const SIGNATURES = [
  "reply channel changed or cannot preserve its sender",
  "No active WhatsApp Web listener",
  "Gateway client authority closed before dispatching",
];

export function decide({ lines, now, linked, restarts }) {
  let ready = 0, listen = 0;
  const events = [];
  for (const l of lines) {
    const sig = SIGNATURES.find((s) => l.includes(s));
    const isReady = l.includes('"gateway ready"');
    const isListen = l.includes("Listening for WhatsApp inbound messages");
    if (!sig && !isReady && !isListen) continue;
    let ts;
    try { ts = Date.parse(JSON.parse(l)._meta.date); } catch { continue; }
    if (!Number.isFinite(ts) || ts > now) continue;
    if (isReady) ready = Math.max(ready, ts);
    if (isListen) listen = Math.max(listen, ts);
    if (sig) events.push(ts);
  }
  const floor = Math.max(now - WINDOW_MS, ready + GRACE_READY_MS, listen + GRACE_LISTEN_MS);
  const n = events.filter((t) => t >= floor).length;
  if (n < MIN_EVENTS) return { action: "ok", reason: `${n} event(s) in window`, events: n };
  if (!linked) return { action: "skip", reason: "WhatsApp not linked", events: n };
  const day = restarts.filter((t) => now - t < 24 * 3600e3);
  if (day.length && now - day.at(-1) < COOLDOWN_MS) return { action: "skip", reason: "cooldown", events: n };
  if (day.length >= MAX_PER_DAY) return { action: "skip", reason: `${day.length} restarts in 24h`, events: n };
  return { action: "restart", reason: "stranded listener", events: n };
}

function readLines(dir) {
  return fs.readdirSync(dir).filter((f) => /^openclaw-\d{4}-\d{2}-\d{2}\.log$/.test(f)).sort().slice(-2)
    .flatMap((f) => fs.readFileSync(path.join(dir, f), "utf8").split("\n"));
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const args = process.argv.slice(2);
  const dry = args.includes("--dry-run");
  const now = args.includes("--now") ? Date.parse(args[args.indexOf("--now") + 1]) : Date.now();
  const stateFile = process.env.GUARD_STATE ?? path.join(os.homedir(), ".local/state/claw/listener-guard.json");
  const restartCmd = process.env.GUARD_RESTART ?? "systemctl --user restart openclaw-gateway.service";
  let state = { restarts: [] };
  try { state = JSON.parse(fs.readFileSync(stateFile, "utf8")); } catch {}
  const lines = readLines(process.env.GUARD_LOG_DIR ?? "/tmp/openclaw");
  const status = () => execFileSync("openclaw", ["channels", "status"], { encoding: "utf8", timeout: 60e3 }).replace(/\x1b\[[0-9;]*m/g, "");
  const pre = decide({ lines, now, linked: true, restarts: state.restarts });
  if (pre.action === "ok") { if (dry) console.log(`ok: ${pre.reason}`); process.exit(0); }
  const linked = /^- WhatsApp default:.*, linked,/m.test(status());
  const r = decide({ lines, now, linked, restarts: state.restarts });
  const msg = `${new Date(now).toISOString()} ${r.action}: ${r.reason} (${r.events} events)`;
  console.log(dry ? `[dry-run] ${msg}` : msg);
  if (r.action !== "restart" || dry) process.exit(0);
  fs.mkdirSync(path.dirname(stateFile), { recursive: true });
  fs.writeFileSync(stateFile, JSON.stringify({ restarts: [...state.restarts.filter((t) => now - t < 24 * 3600e3), now] }));
  execSync(restartCmd, { stdio: "inherit" });
}
```

- [ ] **Step 4: Run the tests**

Run: `make unit`. Expected: all 7 guard tests pass.

- [ ] **Step 5: Write the systemd units**

`ops/listener-guard/openclaw-listener-guard.service`:

```ini
[Unit]
Description=Restart the OpenClaw gateway when its WhatsApp listener is stranded

[Service]
Type=oneshot
Environment=GUARD_LOG_DIR=/tmp/openclaw
ExecStart=/usr/bin/node %h/ops/listener-guard/guard.mjs
```

`ops/listener-guard/openclaw-listener-guard.timer`:

```ini
[Unit]
Description=Run the OpenClaw listener guard every 2 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
```

Journal output replaces the macOS `guard.log`: `journalctl --user -u openclaw-listener-guard`.

- [ ] **Step 6: Commit**

```bash
git add ops/listener-guard/
git commit -m "feat(ops): listener guard with pure decision core, replay tests, systemd timer"
```

---

### Task 7: Export and import

**Files:**
- Create: `migrate/export.sh`, `migrate/import.sh`, `migrate/import.test.sh`

**Interfaces:**
- Consumes: `migrate/binpaths.mjs` CLI and `rewriteArgv` (Task 5), `migrate/scan-refs.mjs` CLI (Task 5), guard units (Task 6), `docs/verification.md` facts (Task 1: restore layout, cron disable key, `config unset`).
- Produces:
  - `export.sh rehearsal|final` on the old VM → `$HOME/claw-export-<mode>-<UTC ts>/` containing `openclaw-backup.tar.gz`, `filestate.tar.gz`, `MANIFEST` (`mode=<mode>` line + `sha256  file` lines). Final mode stops the gateway and the guard first.
  - `import.sh rehearsal|final|drill <export-dir> [--force]` on the new VM. Exit 0 only if every gate passes. `drill` accepts any archive (final, nightly) but, like `rehearsal`, strips both WhatsApp credential sets and disables cron before anything starts — for restore drills of real backups.

- [ ] **Step 1: Write the failing import tests**

`migrate/import.test.sh` exercises the guard rails with a fake export and `IMPORT_DRY=1` (validation only, no restore):

```bash
#!/bin/bash
# Guard-rail tests for import.sh. Needs no OpenClaw: IMPORT_DRY=1 stops after validation.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
pass=0; fail=0
expect() { # expect <exit-code> <description> <cmd...>
  local want="$1" desc="$2"; shift 2
  set +e; "$@" >"$t/out" 2>&1; local got=$?; set -e
  if [ "$got" -eq "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $desc (exit $got, want $want)"; cat "$t/out"; fi
}
mk() { # mk <dir> <mode> <with-wa-creds:yes|no>
  mkdir -p "$1/src/.openclaw/credentials"
  [ "$3" = yes ] && mkdir -p "$1/src/.openclaw/credentials/whatsapp/default" && echo '{}' > "$1/src/.openclaw/credentials/whatsapp/default/creds.json"
  tar -C "$1/src" -czf "$1/openclaw-backup.tar.gz" .openclaw
  tar -C "$1/src" -czf "$1/filestate.tar.gz" .openclaw/credentials
  rm -rf "$1/src"
  (cd "$1" && { echo "mode=$2"; shasum -a 256 openclaw-backup.tar.gz filestate.tar.gz; } > MANIFEST)
}
export IMPORT_DRY=1 IMPORT_HOME="$t/home"
mkdir -p "$t/home"

mk "$t/reh" rehearsal no
expect 0 "rehearsal archive imports as rehearsal" bash "$here/import.sh" rehearsal "$t/reh"
expect 1 "rehearsal archive refused as final"     bash "$here/import.sh" final "$t/reh"

mk "$t/fin" final yes
expect 0 "final archive imports as final"          bash "$here/import.sh" final "$t/fin"
expect 1 "archive with WA creds refused as rehearsal" bash "$here/import.sh" rehearsal "$t/fin"

mk "$t/bad" final yes; echo x >> "$t/bad/filestate.tar.gz"
expect 1 "checksum mismatch refused"               bash "$here/import.sh" final "$t/bad"

mkdir -p "$t/home/.openclaw" && touch "$t/home/.openclaw/openclaw.json"
expect 1 "existing state refused without --force"  bash "$here/import.sh" final "$t/fin"
expect 0 "existing state accepted with --force"    bash "$here/import.sh" final "$t/fin" --force
rm -rf "$t/home/.openclaw"
expect 0 "drill accepts a final archive (credentials stripped after restore)" bash "$here/import.sh" drill "$t/fin"
expect 0 "drill accepts a rehearsal archive"       bash "$here/import.sh" drill "$t/reh"

echo "import guard rails: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

Add it to the Makefile's `unit` target:

```make
unit:
	node --test 'migrate/**/*.test.mjs' 'ops/**/*.test.mjs'
	bash migrate/import.test.sh
```

Run: `make unit`. Expected: fails (`import.sh` missing).

- [ ] **Step 2: Implement `migrate/export.sh`**

```bash
#!/bin/bash
# Run on the OLD (macOS) VM. Usage: export.sh rehearsal|final
set -euo pipefail
mode="${1:?usage: $0 rehearsal|final}"
case "$mode" in rehearsal|final) ;; *) echo "mode must be rehearsal or final" >&2; exit 2 ;; esac
export PATH=/opt/homebrew/bin:$PATH
ts=$(date -u +%Y%m%dT%H%M%SZ)
out="$HOME/claw-export-$mode-$ts"
mkdir -m 700 "$out"

if [ "$mode" = final ]; then
  launchctl bootout "gui/$(id -u)/local.openclaw-listener-guard" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/ai.openclaw.gateway"
  echo "gateway stopped"
fi

set -a; . "$HOME/.openclaw/service-env/ai.openclaw.gateway.env"; set +a
openclaw backup create --output "$out" --verify
mv "$out"/*-openclaw-backup.tar.gz "$out/openclaw-backup.tar.gz"

items=(brain .wacli .ssh/ocsb_vault .ssh/ocsb_vault.pub .ssh/config .ssh/authorized_keys .ssh/known_hosts ops
       .openclaw/service-env/ai.openclaw.gateway.env)
for d in openclaw-agents-retired-* .openclaw-stale-*; do [ -e "$HOME/$d" ] && items+=("$d"); done
excl=(--exclude 'brain/*/node_modules')
[ "$mode" = rehearsal ] && excl+=(--exclude '.wacli/session.db*')
tar -C "$HOME" -czf "$out/filestate.tar.gz" "${excl[@]}" "${items[@]}"

(cd "$out" && { echo "mode=$mode"; shasum -a 256 openclaw-backup.tar.gz filestate.tar.gz; } > MANIFEST)
chmod 600 "$out"/*
du -sh "$out"; cat "$out/MANIFEST"
```

- [ ] **Step 3: Implement `migrate/import.sh`**

```bash
#!/bin/bash
# Run on the NEW (Linux) VM. Usage: import.sh rehearsal|final|drill <export-dir> [--force]
# IMPORT_DRY=1 stops after validation (used by import.test.sh). IMPORT_HOME overrides $HOME for tests.
set -euo pipefail
mode="${1:?usage: $0 rehearsal|final|drill <export-dir> [--force]}"; src="${2:?export dir}"; force="${3:-}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
H="${IMPORT_HOME:-$HOME}"
die() { echo "import: $*" >&2; exit 1; }

# --- validation: nothing is touched until all of it passes ----------------------------------
[ -f "$src/MANIFEST" ] || die "no MANIFEST in $src"
got_mode=$(sed -n 's/^mode=//p' "$src/MANIFEST")
[ "$mode" = drill ] && got_mode=drill   # a drill may restore any archive; it strips credentials below
[ "$got_mode" = "$mode" ] || die "archive is a '$got_mode' export; refusing to import it as '$mode'"
(cd "$src" && grep -v '^mode=' MANIFEST | shasum -a 256 -c -) >/dev/null || die "checksum mismatch in $src"
has_wa=$(tar -tzf "$src/openclaw-backup.tar.gz" | grep -c 'credentials/whatsapp/default/creds.json' || true)
if [ "$mode" = rehearsal ] && [ "$has_wa" -gt 0 ]; then
  die "rehearsal import found WhatsApp credentials in the archive — two gateways must never share them"
fi
if [ -e "$H/.openclaw/openclaw.json" ]; then
  [ "$force" = --force ] || die "$H/.openclaw already has state; re-run with --force to move it aside"
fi
[ "${IMPORT_DRY:-0}" = 1 ] && { echo "import: validation OK ($mode)"; exit 0; }

# --- restore ------------------------------------------------------------------------------
if [ -e "$H/.openclaw" ]; then mv "$H/.openclaw" "$H/.openclaw.pre-import-$(date -u +%Y%m%dT%H%M%SZ)"; fi
systemctl --user stop openclaw-gateway.service 2>/dev/null || true
stage=$(mktemp -d)
openclaw backup restore "$src/openclaw-backup.tar.gz" --target "$stage/r"
restored="$stage/r/payload/posix$H/.openclaw"   # layout recorded in docs/verification.md
[ -d "$restored" ] || die "restore layout unexpected: $restored missing (see docs/verification.md)"
rsync -a "$restored/" "$H/.openclaw/"
rm -rf "$stage"
tar -C "$H" -xzf "$src/filestate.tar.gz"
chmod 600 "$H/.openclaw/service-env/"*.env
no_wa=0; [ "$mode" = rehearsal ] || [ "$mode" = drill ] && no_wa=1
if [ "$no_wa" = 1 ]; then
  rm -rf "$H/.openclaw/credentials/whatsapp" "$H/.openclaw/credentials/whatsapp.backup."* "$H/.wacli/session.db"*
fi

for p in "$H"/brain/*/package-lock.json; do (cd "$(dirname "$p")" && npm ci --no-audit --no-fund); done

# --- platform changes ---------------------------------------------------------------------
node "$repo/migrate/binpaths.mjs" "$H"
openclaw config set plugins.entries.imessage.enabled false
openclaw config unset channels.imessage
if [ "$no_wa" = 1 ]; then openclaw config set cron.enabled false; fi   # key per docs/verification.md

# --- service: OpenClaw's own unit, bootstrap token carried over -----------------------------
tok=$(sed -n 's/^OP_SERVICE_ACCOUNT_TOKEN=//p' "$H/.openclaw/service-env/ai.openclaw.gateway.env")
[ -n "$tok" ] || die "bootstrap token missing from the carried env file"
openclaw gateway install --runtime-path /usr/bin/node --force
envf=$(ls "$H/.openclaw/service-env/"*.env | grep -v 'ai.openclaw.gateway.env' | head -1 || true)
envf="${envf:-$H/.openclaw/service-env/ai.openclaw.gateway.env}"
grep -q '^OP_SERVICE_ACCOUNT_TOKEN=' "$envf" || printf 'OP_SERVICE_ACCOUNT_TOKEN=%s\nexport OP_SERVICE_ACCOUNT_TOKEN\n' "$tok" >> "$envf"
chmod 600 "$envf"
set -a; . "$envf"; set +a
openclaw doctor --fix --non-interactive --allow-exec --yes
systemctl --user enable --now openclaw-gateway.service

# --- command automations: argv[0] to Debian paths, via OpenClaw's own CLI -------------------
export OPENCLAW_GATEWAY_TOKEN; OPENCLAW_GATEWAY_TOKEN=$(op read "op://Sebastian/OpenClaw Gateway Token/password")
sleep 15
openclaw automations list --all --json | node --input-type=module -e '
  import { rewriteArgv, DEFAULT_MAP } from "'"$repo"'/migrate/binpaths.mjs";
  import { execFileSync } from "node:child_process";
  let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
    const j = JSON.parse(s); const jobs = j.automations ?? j.jobs ?? j;
    for (const x of jobs) {
      const argv = x.payload?.argv; if (x.payload?.kind !== "command" || !argv) continue;
      const r = rewriteArgv(argv, DEFAULT_MAP); if (!r.changed) continue;
      execFileSync("openclaw", ["cron", "edit", x.id, "--command-argv", JSON.stringify(r.argv)], { stdio: "inherit" });
      console.log(`automation ${x.name}: argv[0] ${argv[0]} -> ${r.argv[0]}`);
    }
  });'

# --- guard + gates ----------------------------------------------------------------------------
install -d "$H/.config/systemd/user" "$H/ops/listener-guard"
cp "$repo/ops/listener-guard/guard.mjs" "$H/ops/listener-guard/"
cp "$repo/ops/listener-guard/"*.service "$repo/ops/listener-guard/"*.timer "$H/.config/systemd/user/"
if [ "$mode" = final ]; then
  install -d "$H/ops/backup"
  cp "$repo/ops/backup/nightly-backup.sh" "$H/ops/backup/"
  cp "$repo/ops/backup/"*.service "$repo/ops/backup/"*.timer "$H/.config/systemd/user/"
fi
systemctl --user daemon-reload && systemctl --user enable --now openclaw-listener-guard.timer
[ "$mode" = final ] && systemctl --user enable --now openclaw-nightly-backup.timer

SCAN_ALLOW="$repo/migrate/scan-allow.txt" node "$repo/migrate/scan-refs.mjs" "$H/brain" "$H/ops" "$H/.openclaw/workspace/skills" "$H/.openclaw/workspace-vera/skills" \
  || die "free-text scan found references that break on Linux (see above); fix or allow-list them"
openclaw secrets audit --allow-exec
echo "import: done ($mode). Now run tests/acceptance.sh $mode"
```

Before running Step 5, confirm the gateway unit name and the scheduler key against `docs/verification.md` and edit the three lines that use them (`openclaw-gateway.service`, `cron.enabled`) if they differ.

- [ ] **Step 4: Run the guard-rail tests**

Run: `make unit`. Expected: `import guard rails: 9 passed, 0 failed`, plus the node tests.

- [ ] **Step 5: Exercise export on the old VM (rehearsal mode only)**

```bash
scp migrate/export.sh admin@vm-claw:/tmp/ && ssh admin@vm-claw 'bash /tmp/export.sh rehearsal'
```

Expected: a `claw-export-rehearsal-…` directory with three files, `MANIFEST` first line `mode=rehearsal`, and `tar -tzf …/filestate.tar.gz | grep session.db` printing nothing. The gateway keeps running (rehearsal never stops it).

- [ ] **Step 6: Lint and commit**

```bash
make lint && make unit
git add migrate/export.sh migrate/import.sh migrate/import.test.sh Makefile
git commit -m "feat(migrate): export/import with mode, checksum and state guard rails"
```

---

### Task 8: Backups off the VM

**Files:**
- Create: `ops/backup/nightly-backup.sh`, `ops/backup/openclaw-nightly-backup.service`, `ops/backup/openclaw-nightly-backup.timer`, `host/pull-backups.sh`, `host/local.vm-claw.pull-backups.plist`

**Interfaces:**
- Produces: guest `~/backups/claw-nightly-<UTC ts>/` (same layout as an export: `openclaw-backup.tar.gz`, `filestate.tar.gz`, `MANIFEST` with `mode=nightly`), keep 7; host `~/Backups/vm-claw/claw-nightly-*`, keep 14; restic snapshots of that folder.

- [ ] **Step 1: Write the guest nightly script**

`ops/backup/nightly-backup.sh`:

```bash
#!/bin/bash
# Guest nightly backup. Same layout as a migration export, mode=nightly; keeps 7.
set -euo pipefail
ts=$(date -u +%Y%m%dT%H%M%SZ)
out="$HOME/backups/claw-nightly-$ts"
mkdir -p -m 700 "$out"
set -a; . "$(ls "$HOME"/.openclaw/service-env/*.env | head -1)"; set +a
openclaw backup create --output "$out" --verify
mv "$out"/*-openclaw-backup.tar.gz "$out/openclaw-backup.tar.gz"
tar -C "$HOME" -czf "$out/filestate.tar.gz" --exclude 'brain/*/node_modules' \
  brain .wacli .ssh ops .openclaw/service-env
(cd "$out" && { echo "mode=nightly"; sha256sum openclaw-backup.tar.gz filestate.tar.gz; } > MANIFEST)
chmod 600 "$out"/*
ls -dt "$HOME"/backups/claw-nightly-* | tail -n +8 | xargs -r rm -rf
```

The MANIFEST uses `sha256sum` (Linux); `import.sh` checks it with `shasum -a 256 -c`, which reads the same format.

- [ ] **Step 2: Write the guest units**

`ops/backup/openclaw-nightly-backup.service`:

```ini
[Unit]
Description=Nightly OpenClaw backup

[Service]
Type=oneshot
ExecStart=/bin/bash %h/ops/backup/nightly-backup.sh
```

`ops/backup/openclaw-nightly-backup.timer`:

```ini
[Unit]
Description=Nightly OpenClaw backup at 03:30 UTC

[Timer]
OnCalendar=*-*-* 03:30:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
```

- [ ] **Step 3: Write the host pull + restic script**

`host/pull-backups.sh`:

```bash
#!/bin/bash
# Host: pull the newest guest backup (host -> guest direction only), keep 14, then restic off-site.
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH
dest="$HOME/Backups/vm-claw"
mkdir -p -m 700 "$dest"
latest=$(limactl shell claw -- bash -lc 'ls -dt ~/backups/claw-nightly-* 2>/dev/null | head -1')
[ -n "$latest" ] || { echo "pull-backups: no nightly backup in the guest" >&2; exit 1; }
name=$(basename "$latest")
if [ ! -d "$dest/$name" ]; then
  limactl copy -r "claw:$latest" "$dest/$name.partial"
  (cd "$dest/$name.partial" && grep -v '^mode=' MANIFEST | shasum -a 256 -c -) >/dev/null
  mv "$dest/$name.partial" "$dest/$name"
fi
ls -dt "$dest"/claw-nightly-* | tail -n +15 | xargs -r rm -rf

export RESTIC_REPOSITORY="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups/vm-claw-restic"
export RESTIC_PASSWORD_COMMAND="security find-generic-password -s vm-claw-restic -w"
restic snapshots >/dev/null 2>&1 || restic init
restic backup --tag vm-claw "$dest"
restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune
```

- [ ] **Step 4: Write the host schedule**

`host/local.vm-claw.pull-backups.plist` (the `ProgramArguments` path is the repo checkout on the host; `host/install.sh` in Task 11 substitutes it):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.vm-claw.pull-backups</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>@REPO@/host/pull-backups.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>15</integer></dict>
  <key>StandardOutPath</key><string>@HOME@/Library/Logs/vm-claw-pull-backups.log</string>
  <key>StandardErrorPath</key><string>@HOME@/Library/Logs/vm-claw-pull-backups.log</string>
</dict>
</plist>
```

- [ ] **Step 5: Lint and commit**

```bash
make lint
git add ops/backup/ host/pull-backups.sh host/local.vm-claw.pull-backups.plist
git commit -m "feat(ops): nightly guest backups, host pull, restic off-site"
```

---

### Task 9: Acceptance script

**Files:**
- Create: `tests/acceptance.sh`

**Interfaces:**
- Consumes: `tests/firewall-check.sh`, guard (`guard.mjs --dry-run`).
- Produces: `acceptance.sh rehearsal|final <lan-ip>` inside the guest; prints `PASS`/`FAIL`/`MANUAL` per checklist item; exits non-zero on any `FAIL`.

- [ ] **Step 1: Write it**

```bash
#!/bin/bash
# Guest-side acceptance checks (spec §3 checklist). Items needing a human print MANUAL.
set -uo pipefail
mode="${1:?usage: $0 rehearsal|final <lan-ip>}"; lan="${2:?lan ip}"
here="$(cd "$(dirname "$0")" && pwd)"
set -a; . "$(ls "$HOME"/.openclaw/service-env/*.env | head -1)"; set +a
export OPENCLAW_GATEWAY_TOKEN; OPENCLAW_GATEWAY_TOKEN=$(op read "op://Sebastian/OpenClaw Gateway Token/password")
fail=0
item() { local name="$1"; shift; if "$@" >/tmp/acc.out 2>&1; then echo "PASS   $name"; else echo "FAIL   $name"; sed 's/^/       /' /tmp/acc.out | tail -5; fail=1; fi; }
manual() { echo "MANUAL $1"; }

item "secrets audit: 0 unresolved" sh -c 'openclaw secrets audit --allow-exec | grep -q "unresolved=0"'
item "update status: last run succeeded" sh -c 'openclaw update status --json | grep -q "\"status\": *\"succeeded\""'
item "agent probe: primary"  sh -c 'openclaw agent --agent main --session-key bench:acc-primary -m "Reply with exactly: pong" --json | grep -q pong'
item "agent probe: fallback" sh -c 'openclaw agent --agent main --session-key bench:acc-fallback --model openai/gpt-6-luna -m "Reply with exactly: pong" --json | grep -q pong'
item "firewall" bash "$here/firewall-check.sh" "$lan"
item "listener guard dry run" node "$HOME/ops/listener-guard/guard.mjs" --dry-run
item "vault remote reachable with deploy key" git -C "$HOME/brain/vault" ls-remote origin HEAD
openclaw sessions delete agent:main:bench:acc-primary agent:main:bench:acc-fallback --agent main --yes >/dev/null 2>&1 || true

if [ "$mode" = final ]; then
  item "WhatsApp linked + connected" sh -c 'openclaw channels status | grep -E "^- WhatsApp default:.*, linked, running, connected"'
  item "wacli authenticated" sh -c 'wacli auth status --read-only --json | grep -q "\"authenticated\":true"'
  item "harvest health ok" sh -c 'grep -q "\"ok\":true" ~/brain/queue/harvest-health.json'
  manual "one real WhatsApp message gets a reply"
  manual "first scheduled ocsb-ingest and one announce job succeed (openclaw automations list --json)"
  manual "face in gateway presence (host: the panel shows the face); voice-gateway chat.send round-trips"
  manual "restore drill (Task 13)"
fi
[ "$fail" -eq 0 ] && echo "acceptance ($mode): automated items PASS"
exit "$fail"
```

- [ ] **Step 2: Lint and commit**

```bash
make lint
git add tests/acceptance.sh
git commit -m "test: acceptance checklist script"
```

---

### Task 10: Safety net, baseline, and rehearsal on the dev Mac

**Files:** none (operational). Record outcomes in `docs/verification.md` under a new `## Rehearsal (date)` heading.

- [ ] **Step 1: Safety net on the host (spec §3 Step 0)**

On the old VM and host:

```bash
ssh admin@vm-claw 'bash /tmp/export.sh rehearsal'            # fresh, gateway keeps running
ssh -4 <host> 'mkdir -p -m 700 ~/Backups/vm-claw-pre-linux'
scp -r admin@vm-claw:'~/claw-export-rehearsal-*' <host>:~/Backups/vm-claw-pre-linux/
ssh admin@vm-claw 'launchctl bootout gui/$(id -u)/ai.openclaw.gateway'   # close the databases cleanly first
ssh -4 <host> 'export PATH=/opt/homebrew/bin:$PATH; launchctl bootout gui/$(id -u)/com.vm-claw.agent; tart clone vm-claw vm-claw-pre-linux; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.vm-claw.agent.plist'
```

The gateway's own launchd agent brings it back when the VM boots. The clone needs the VM stopped for ~1 minute (WhatsApp reconnects on its own; the listener guard covers a stranded listener). Expected: `tart list` shows `vm-claw-pre-linux`.

- [ ] **Step 2: Baseline**

```bash
ssh admin@vm-claw 'export PATH=/opt/homebrew/bin:$PATH; set -a; . ~/.openclaw/service-env/ai.openclaw.gateway.env; set +a;
  openclaw doctor --non-interactive --allow-exec > ~/baseline-doctor.txt 2>&1;
  openclaw secrets audit --allow-exec > ~/baseline-secrets.txt 2>&1;
  OPENCLAW_GATEWAY_TOKEN=$(op read "op://Sebastian/OpenClaw Gateway Token/password") openclaw automations list --all --json > ~/baseline-automations.json'
scp admin@vm-claw:'~/baseline-*' <host>:~/Backups/vm-claw-pre-linux/
```

- [ ] **Step 3: Rehearsal on the dev Mac**

```bash
host/claw.sh destroy; host/claw.sh create --memory 8 && host/claw.sh start && host/claw.sh provision
scp -r admin@vm-claw:'~/claw-export-rehearsal-*' /tmp/
limactl copy -r /tmp/claw-export-rehearsal-* claw:/tmp/export
limactl copy -r . claw:/Users/admin/vm-claw
host/claw.sh shell -- bash ~/vm-claw/migrate/import.sh rehearsal /tmp/export
host/claw.sh shell -- bash ~/vm-claw/tests/acceptance.sh rehearsal <router-ip>
```

Expected: `import: done (rehearsal)` and `acceptance (rehearsal): automated items PASS`. Also check by hand and record: `openclaw channels status` shows WhatsApp **not linked** (credentials excluded) and no iMessage; `openclaw automations list` shows the scheduler disabled; `ls ~/.openclaw/agents/main/agent/` has the agent DB; `openclaw sessions --all-agents --json | jq '.sessions | length'` equals the old VM's count; `wacli doctor --read-only --json` opens the migrated store and reports its message count (authenticated `false` is expected — the session was excluded); `ls /tmp/openclaw/` shows `openclaw-<date>.log` (the guard's log path) — if OpenClaw logs elsewhere on Linux, set `GUARD_LOG_DIR` in the guard's `.service` file; `openclaw doctor --non-interactive` shows no browser/Chromium error — if it cannot find Chromium, set its executable path in config to `/usr/bin/chromium`.

- [ ] **Step 4: Discard the rehearsal**

`host/claw.sh destroy` on the dev Mac, and `rm -rf /tmp/claw-export-rehearsal-*`. The rehearsal copy held live secrets; nothing of it stays on the dev Mac.

- [ ] **Step 5: Commit the record**

```bash
git add docs/verification.md
git commit -m "docs: rehearsal results"
```

---

### Task 11: Host install and pre-provisioning on the appliance

**Files:**
- Create: `host/install.sh`

**Interfaces:**
- Produces: `host/install.sh` installs Lima and restic from Homebrew core, checks iCloud Drive, stores the restic password in the login keychain, and installs the pull-backups agent (substituting `@REPO@`/`@HOME@`). Idempotent. Autostart is not registered here.

- [ ] **Step 1: Write `host/install.sh`**

```bash
#!/bin/bash
# Host setup: Lima + restic, backup pull agent, autostart. Safe to re-run.
set -euo pipefail
export PATH=/opt/homebrew/bin:$PATH
repo="$(cd "$(dirname "$0")/.." && pwd)"
command -v limactl >/dev/null || brew install lima
command -v restic >/dev/null || brew install restic
[ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ] || {
  echo "iCloud Drive is not enabled on this Mac: enable it, or change RESTIC_REPOSITORY in host/pull-backups.sh" >&2; exit 1; }
security find-generic-password -s vm-claw-restic >/dev/null 2>&1 || {
  echo "Store the restic password (also saved in 1Password) in the login keychain:"
  security add-generic-password -s vm-claw-restic -a "$USER" -w
}
plist="$HOME/Library/LaunchAgents/local.vm-claw.pull-backups.plist"
sed -e "s#@REPO@#$repo#g" -e "s#@HOME@#$HOME#g" "$repo/host/local.vm-claw.pull-backups.plist" > "$plist"
launchctl bootout "gui/$(id -u)/local.vm-claw.pull-backups" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
# Autostart is registered at cutover (Task 12), not here: the new VM must not boot at
# login while the old one still owns the WhatsApp credentials.
```

- [ ] **Step 2: Clone the repo onto the host and pre-provision at 4 GiB**

```bash
ssh -4 <host> 'git clone https://github.com/intinig/vm-claw.git ~/s/vm-claw'   # or pull if present
ssh -4 <host> 'cd ~/s/vm-claw && host/claw.sh create --memory 4 && host/claw.sh start && host/claw.sh provision && tests/isolation-check.sh'
```

Expected: `isolation: OK`. The Tart VM keeps running (8 GiB + 4 GiB fits in 16 GB for provisioning).

- [ ] **Step 3: Tailscale in the new guest under a temporary name**

```bash
ssh -4 <host> 'cd ~/s/vm-claw && host/claw.sh shell -- sudo tailscale up --hostname=vm-claw-lima'
```

The owner approves the printed login URL. Expected: `tailscale status` lists `vm-claw-lima`. It is renamed at cutover.

- [ ] **Step 4: Install host pieces, stop the guest until cutover**

```bash
ssh -t -4 <host> 'cd ~/s/vm-claw && bash host/install.sh && host/claw.sh stop'
```

Expected: `launchctl list | grep local.vm-claw.pull-backups` shows the agent; `limactl list` shows `claw` Stopped.

- [ ] **Step 5: Commit**

```bash
make lint
git add host/install.sh
git commit -m "feat(host): install script for Lima, restic, backup pull, autostart"
```

---

### Task 12: Cutover (owner present) and docs

**Files:**
- Modify: `README.md`, `CLAUDE.md` (rewritten for the Lima setup; keep the Tart section under "Rollback" until Task 14)

- [ ] **Step 1: Final export (downtime starts)**

```bash
scp migrate/export.sh admin@vm-claw:/tmp/ && ssh admin@vm-claw 'bash /tmp/export.sh final'
scp -r admin@vm-claw:'~/claw-export-final-*' <host>:~/Backups/vm-claw-pre-linux/
```

Expected: `gateway stopped`, `MANIFEST` begins `mode=final`.

- [ ] **Step 2: Retire the old VM**

```bash
ssh admin@vm-claw 'sudo tailscale set --hostname=vm-claw-tart'
ssh -4 <host> 'launchctl bootout gui/$(id -u)/com.vm-claw.agent; mv ~/Library/LaunchAgents/com.vm-claw.agent.plist ~/Library/LaunchAgents/com.vm-claw.agent.plist.disabled'
```

- [ ] **Step 3: Import on the new VM**

```bash
ssh -4 <host> 'cd ~/s/vm-claw && limactl edit claw --set ".memory = \"8GiB\"" --tty=false && host/claw.sh start &&
  limactl copy -r ~/Backups/vm-claw-pre-linux/claw-export-final-* claw:/tmp/export &&
  limactl copy -r . claw:/Users/admin/vm-claw &&
  host/claw.sh shell -- bash ~/vm-claw/migrate/import.sh final /tmp/export &&
  host/claw.sh shell -- sudo tailscale set --hostname=vm-claw'
```

Expected: `import: done (final)`; `tailscale status` shows `vm-claw` (the new node) and `vm-claw-tart` offline.

- [ ] **Step 4: Host switch-over**

```bash
ssh -4 <host> 'for f in ~/Library/LaunchAgents/*ziel-gateway-tunnel.plist; do launchctl bootout gui/$(id -u) "$f"; mv "$f" "$f.disabled"; done;
  export PATH=/opt/homebrew/bin:$PATH; limactl start-at-login claw'
```

(`start-at-login` is deprecated in Lima 2.2 in favour of `limactl autostart`, but still works; switch when the deprecation becomes removal.)

Expected: `nc -z 127.0.0.1 18789` on the host succeeds through Lima's forward; within a minute the face reconnects (gateway presence lists `gateway-client`).

- [ ] **Step 5: Acceptance (downtime ends when this passes)**

```bash
ssh -4 <host> 'cd ~/s/vm-claw && host/claw.sh shell -- bash ~/vm-claw/tests/acceptance.sh final <router-ip>'
```

Then the owner confirms each `MANUAL` line. Any `FAIL` → fix forward if it is small; otherwise roll back (README "Rollback").

- [ ] **Step 6: Rewrite README.md and CLAUDE.md**

README sections: Overview (isolation properties), Layout (the File Structure table above), Build (`host/claw.sh create|provision`), Migrate (export/import, rehearsal first), Operate (backups, upgrades: `unattended-upgrades`, `openclaw update`, Debian major in place or rebuild, `brew upgrade lima`), Restore (import a `claw-nightly-*` with `import.sh final <dir> --force`, since nightly and final share a layout — add `nightly` to import's accepted modes by treating it as `final`), Rollback (spec §3 procedure, including copying WhatsApp and wacli credentials back). CLAUDE.md: replace the Tart reference with the Lima commands, the Global Constraints above, and "never commit identifiers".

For the Restore section's `nightly` mode, change the first validation lines of `import.sh`:

```bash
got_mode=$(sed -n 's/^mode=//p' "$src/MANIFEST")
[ "$got_mode" = nightly ] && [ "$mode" = final ] && got_mode=final
[ "$got_mode" = "$mode" ] || die "archive is a '$got_mode' export; refusing to import it as '$mode'"
```

and add to `import.test.sh`: `mk "$t/nig" nightly yes; expect 0 "nightly archive imports as final" bash "$here/import.sh" final "$t/nig"`.

- [ ] **Step 7: Commit**

```bash
make lint && make unit
git add README.md CLAUDE.md migrate/import.sh migrate/import.test.sh
git commit -m "docs: runbook for the Lima VM; import accepts nightly backups as final"
```

---

### Task 13: Restore drill and first backup cycle

**Files:** none (operational). Record in `docs/verification.md`.

- [ ] **Step 1: First nightly and pull**

The morning after cutover:

```bash
ssh -4 <host> 'cd ~/s/vm-claw && host/claw.sh shell -- ls -d ~/backups/claw-nightly-*; cat ~/Library/Logs/vm-claw-pull-backups.log | tail -5;
  RESTIC_REPOSITORY="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups/vm-claw-restic" RESTIC_PASSWORD_COMMAND="security find-generic-password -s vm-claw-restic -w" /opt/homebrew/bin/restic snapshots'
```

Expected: one nightly dir in the guest, a successful pull in the log, one restic snapshot.

- [ ] **Step 2: Restore drill into a scratch instance on the dev Mac**

```bash
limactl create --name=claw-drill --memory=4 --tty=false lima/claw.yaml && limactl start claw-drill
# provision claw-drill the same way host/claw.sh does, with inst=claw-drill
scp -r <host>:'~/Backups/vm-claw/claw-nightly-*' /tmp/drill/   # newest only
limactl copy -r /tmp/drill/claw-nightly-* claw-drill:/tmp/export
limactl copy -r . claw-drill:/Users/admin/vm-claw
limactl shell claw-drill -- bash ~/vm-claw/migrate/import.sh rehearsal /tmp/export   # must REFUSE: a nightly holds WhatsApp credentials
limactl shell claw-drill -- bash ~/vm-claw/migrate/import.sh drill /tmp/export
```

Expected: the `rehearsal` attempt refuses (Review Focus 1 in the wild); the `drill` import completes with WhatsApp not linked and cron disabled. Confirm the session count and automation count match the live VM and that `tar -tzf /tmp/drill/claw-nightly-*/openclaw-backup.tar.gz | grep -c credentials/whatsapp/default/creds.json` is 1 (the real credentials are in the backup even though the drill stripped them). Then `limactl delete --force claw-drill && rm -rf /tmp/drill`.

- [ ] **Step 3: Record and commit**

```bash
git add docs/verification.md
git commit -m "docs: restore drill and first backup cycle results"
```

---

### Task 14: Retire Tart (14 days after cutover, no rollback)

**Files:**
- Delete: `setup.sh`, `run.sh`
- Modify: `README.md` (drop the Tart rollback section), `CLAUDE.md`

- [ ] **Step 1: Delete the old VM and its clone**

```bash
ssh -4 <host> 'export PATH=/opt/homebrew/bin:$PATH; tart delete vm-claw; tart delete vm-claw-pre-linux; rm ~/Library/LaunchAgents/com.vm-claw.agent.plist.disabled ~/Library/LaunchAgents/*ziel-gateway-tunnel.plist.disabled'
```

Remove the `vm-claw-tart` node in the Tailscale admin console.

- [ ] **Step 2: Remove Tart from the repo and commit**

```bash
git rm setup.sh run.sh
git add README.md CLAUDE.md
git commit -m "chore: retire the Tart VM"
```
