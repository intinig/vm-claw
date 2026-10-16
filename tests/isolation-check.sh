#!/bin/bash
# Host-side isolation check for the `claw` Lima instance. Exits 1 on any violation.
set -euo pipefail
inst="${1:-${CLAW_INSTANCE:-claw}}"
# Same rule as host/claw.sh: the name reaches limactl and a log path, so validate it first.
if ! [[ $inst =~ ^[a-z0-9][a-z0-9-]*$ ]]; then echo "isolation-check.sh: instance '$inst' is not an instance name (a-z, 0-9, -)" >&2; exit 2; fi
fail=0
bad() { echo "FAIL: $*"; fail=1; }
g() { limactl shell "$inst" -- "$@"; }
hostagent_log="${LIMA_HOME:-$HOME/.lima}/$inst/ha.stderr.log"

# Probe listeners must never outlive the check, even on an abort.
# Probe ports are chosen at run time from 41000-41999; the bracketed pattern cannot match its own command line.
kill_probes() { g sh -c 'pkill -f "http.server 41[0-9][0-9][0-9] "' >/dev/null 2>&1 || true; }
trap kill_probes EXIT

# 1. No host filesystem mounted into the guest.
if g sh -c 'mount | grep -E "virtiofs|9p|sshfs|fuse\.sshfs"' >/dev/null 2>&1; then
  bad "guest has host mounts: $(g sh -c 'mount | grep -E "virtiofs|9p|sshfs"')"
fi

# 2. Only 18789 is forwarded. Open two probe listeners in the guest and try them from the host.
#    A probe that cannot be confirmed must fail the check, never pass it.
[ -r "$hostagent_log" ] || { echo "FAIL: hostagent log not readable: $hostagent_log"; exit 1; }
kill_probes   # stale listeners from an aborted run would produce no fresh Lima decision
sleep 1

# 2.0 Pick two probe ports that are free on BOTH sides, so a host service can never be mistaken for a forward
#     (and a guest service can never be mistaken for a probe). 18789 is never a candidate.
guest_listen=$(g ss -ltn 2>/dev/null) || { echo "FAIL: cannot list guest listeners (ss -ltn)"; exit 1; }
host_port_free() {
  ! nc -z -G 2 127.0.0.1 "$1" >/dev/null 2>&1 && [ -z "$(lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null)" ]
}
guest_port_free() { ! grep -qE "[:.]$1[[:space:]]" <<<"$guest_listen"; }
probes=()
for p in $(seq 41000 41999); do
  [ "$p" -eq 18789 ] && continue
  if host_port_free "$p" && guest_port_free "$p"; then
    probes+=("$p")
    [ "${#probes[@]}" -eq 2 ] && break
  fi
done
[ "${#probes[@]}" -eq 2 ] || { echo "FAIL: could not find two ports free on both host and guest in 41000-41999"; exit 1; }
p_lo=${probes[0]} p_all=${probes[1]}
echo "isolation: probing guest ports $p_lo (127.0.0.1) and $p_all (0.0.0.0)"

log_offset=$(wc -l < "$hostagent_log")   # only lines written after this point count as evidence
g sh -c 'nohup python3 -m http.server '"$p_lo"' --bind 127.0.0.1 >/dev/null 2>&1 & nohup python3 -m http.server '"$p_all"' --bind 0.0.0.0 >/dev/null 2>&1 &'

# 2a. Both listeners are really up in the guest (python3 missing or a taken port must not pass vacuously).
# shellcheck disable=SC2016  # the loop must expand in the guest shell; the ports are passed as $1/$2
if ! g sh -c 'for _ in $(seq 1 20); do
  if ss -ltn | grep -qE "[[:space:]]127\.0\.0\.1:$1[[:space:]]" && ss -ltn | grep -qE "[[:space:]]0\.0\.0\.0:$2[[:space:]]"; then exit 0; fi
  sleep 0.5
done
exit 1' _ "$p_lo" "$p_all"; then
  echo "FAIL: probe listener did not start"
  exit 1
fi

# 2b. Lima's hostagent has decided what to do with each listener ("Forwarding ..." or "Not forwarding ...").
#     Wait for that decision before probing from the host, so the probe cannot run ahead of Lima.
lima_decided() {
  tail -n +"$((log_offset + 1))" "$hostagent_log" | grep -E "(Not forwarding TCP|Forwarding TCP from) .*:$1( |\")" >/dev/null
}
for p in "$p_lo" "$p_all"; do
  seen=0
  for _ in $(seq 1 30); do
    if lima_decided "$p"; then seen=1; break; fi
    sleep 0.5
  done
  if [ "$seen" -eq 0 ]; then
    echo "FAIL: no forwarding decision for probe port $p in $hostagent_log within 15s; cannot confirm isolation"
    exit 1
  fi
done

# 2c. Now that Lima has evaluated both listeners, neither may be reachable from the host.
for p in "$p_lo" "$p_all"; do
  if nc -z -G 2 127.0.0.1 "$p" 2>/dev/null; then bad "guest port $p is forwarded to the host"; fi
done

# 3. The guest has no address on the host's LAN.
lan_if=$(route -n get default | awk '/interface:/{print $2}')
lan_net=$(ipconfig getifaddr "$lan_if" | cut -d. -f1-3)
if g sh -c "ip -4 -o addr | grep -q ' ${lan_net}\.'"; then bad "guest has an address in the host LAN ${lan_net}.0/24"; fi

[ "$fail" -eq 0 ] && echo "isolation: OK"
exit "$fail"
