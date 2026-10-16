#!/bin/bash
# Idempotent step helpers. A step runs its check first and only applies on failure.
CHANGED=0; OK=0

# Checks and applies run in a fresh `bash -c`, which does not inherit this shell's set -e/pipefail,
# so each one gets its own: a failing command anywhere in a multi-command apply (a bad checksum, a
# cut-off download) aborts that apply instead of being ignored. Because checks run under pipefail
# too, a check that pipes a long producer into `grep -q` can fail on SIGPIPE (status 141) even
# though it matched; use plain `grep` (output is discarded anyway) for those.
step() {  # step <name> <check-command> <apply-command>
  local name="$1" check="$2" apply="$3"
  if bash -eo pipefail -c "$check" >/dev/null 2>&1; then OK=$((OK+1)); echo "ok      $name"; return; fi
  echo "change  $name"
  bash -eo pipefail -c "$apply" || { echo "FAILED  $name (apply failed)"; exit 1; }
  bash -eo pipefail -c "$check" >/dev/null 2>&1 || { echo "FAILED  $name (check still fails after apply)"; exit 1; }
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

# The guest's own infrastructure IPv4 addresses (default gateway plus the nameservers named in the
# given resolv.conf files), deduplicated, loopback excluded, joined as "a, b" for an nft set.
# Empty output means none were found; callers must treat that as an error.
# /etc/resolv.conf is only the 127.0.0.53 stub under systemd-resolved: pass the real uplink file too.
infra_addrs() {  # infra_addrs <resolv.conf>...
  { ip -4 route show default | awk '{print $3; exit}'
    awk '/^nameserver/{print $2}' "$@" 2>/dev/null
  } | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | grep -v '^127\.' | sort -u | paste -sd, - | sed 's/,/, /g' || true
}

# assert <name> <check-command>: a state provisioning must find and never creates or removes (granting or taking
# away a privilege is a deliberate, manual act). Counts as ok, or stops the run.
assert() {
  local name="$1" check="$2"
  if bash -eo pipefail -c "$check" >/dev/null 2>&1; then OK=$((OK+1)); echo "ok      $name"; return; fi
  echo "FAILED  $name (assertion: provisioning does not change this; see the check in provision.sh)"; exit 1
}

# install_sshd_dropin <dest> <directive-line>: put a sshd drop-in in place only if the whole config is valid with it.
# The directive is written to a hidden temp file next to <dest> (sshd reads only *.conf, so it is inert there),
# prepended to a copy of the main config and checked with `sshd -t -f`; only then is it renamed into place. A rejected
# file is removed, <dest> is left as it was, and the return is 1: a bad drop-in must never reach a restart or reboot.
install_sshd_dropin() {
  local dest="$1" line="$2" cfg="${SSHD_CONFIG:-/etc/ssh/sshd_config}" tmp trial
  tmp="$(dirname "$dest")/.$(basename "$dest").tmp"; trial=$(mktemp)
  printf '%s\n' "$line" > "$tmp"
  if cat "$tmp" "$cfg" > "$trial" && sshd -t -f "$trial"; then rm -f "$trial"; mv "$tmp" "$dest"; return 0; fi
  rm -f "$tmp" "$trial"; return 1
}

summary() { echo "provision: changed=$CHANGED ok=$OK"; }
