#!/bin/bash
# Host-side wrapper around limactl. CLAW_INSTANCE (default claw) picks the instance, for drills and rebuilds.
#   create [--memory GiB]  a new instance from lima/claw.yaml (8 GiB by default)
#   deploy                 the committed tree (git archive HEAD) to /opt/vm-claw: root-owned, read-only for others
#   provision              deploy, then provisioning from /opt/vm-claw as root (idempotent)
#   start | stop | destroy
#   shell [-- cmd…]        a shell or a command as admin (Lima's login user, with sudo)
#   sebastian -- cmd…      a command as the bot account, with XDG_RUNTIME_DIR and the D-Bus address set
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=provision/bot.sh
. "$repo/provision/bot.sh"
inst="${CLAW_INSTANCE:-claw}"
usage() { echo "usage: [CLAW_INSTANCE=name] $0 create [--memory GiB] | deploy | provision | start | stop | shell [-- cmd…] | sebastian -- cmd… | destroy" >&2; exit 2; }
# A Lima instance name and nothing else: it lands in limactl arguments.
if ! [[ $inst =~ ^[a-z0-9][a-z0-9-]*$ ]]; then echo "claw.sh: CLAW_INSTANCE '$inst' is not an instance name (a-z, 0-9, -)" >&2; exit 2; fi

# Runs as root in the guest: $1 = the target dir, $2 = the commit. The archive arrives on stdin, never as a file in
# a directory the bot can write (/tmp), and the tree replaces the old one only once it is complete.
# shellcheck disable=SC2016  # expanded by the guest's bash, not here
deploy_script='set -euo pipefail
new="$1.new"; old="$1.old"
rm -rf "$new" "$old"; mkdir -m 755 "$new"
tar -xf - -C "$new"
if [ ! -f "$new/provision/provision.sh" ]; then echo "deploy: the archive is empty or incomplete (no provision/provision.sh)" >&2; rm -rf "$new"; exit 1; fi
printf "%s\n" "$2" > "$new/DEPLOYED"
chown -R root:root "$new"; chmod -R u=rwX,go=rX "$new"
if [ -e "$1" ]; then mv "$1" "$old"; fi
mv "$new" "$1"; rm -rf "$old"'

deploy() {
  local rev
  rev=$(git -C "$repo" rev-parse HEAD)
  if [ -n "$(git -C "$repo" status --porcelain)" ]; then echo "claw.sh: note: uncommitted changes are not deployed (deploy ships HEAD $rev)" >&2; fi
  git -C "$repo" archive --format=tar HEAD | limactl shell --workdir / "$inst" -- sudo -n bash -c "$deploy_script" _ "$CLAW_REPO" "$rev"
  echo "deploy: $rev at $CLAW_REPO in $inst"
}

case "${1:-}" in
  create)
    mem=8
    if [ "${2:-}" = "--memory" ]; then mem="${3:-}"; [ -n "$mem" ] || usage; fi
    limactl create --name="$inst" --memory="$mem" --tty=false "$repo/lima/claw.yaml"
    ;;
  deploy) deploy ;;
  provision)
    deploy
    # The staging copy older versions of this script left; provisioning now runs from the deployed tree.
    limactl shell --workdir / "$inst" -- sudo -n rm -rf /opt/claw-provision
    limactl shell --workdir / "$inst" -- sudo -n bash "$CLAW_REPO/provision/provision.sh"
    ;;
  start)   limactl start "$inst" ;;
  stop)    limactl stop "$inst" ;;
  shell)
    shift
    if [ "${1:-}" = "--" ]; then shift; fi
    limactl shell "$inst" -- "$@"
    ;;
  sebastian)
    shift
    if [ "${1:-}" != "--" ]; then usage; fi
    shift
    if [ "$#" -eq 0 ]; then usage; fi
    limactl shell --workdir / "$inst" -- "${BOT_SESSION[@]}" "$@"
    ;;
  destroy) limactl delete --force "$inst" ;;
  *) usage ;;
esac
