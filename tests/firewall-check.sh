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
