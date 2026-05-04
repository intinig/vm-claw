#!/bin/bash
# Bootstrap a macOS host for running Hermes Agent in Docker via Colima.
# Follows https://hermes-agent.nousresearch.com/docs/user-guide/docker — Hermes
# itself runs inside the nousresearch/hermes-agent container; ~/.hermes is
# bind-mounted to /opt/data and is the single source of truth for state.
#
# This script does the prerequisite work only:
#   - Homebrew (if missing), Colima, docker CLI, docker-compose
#   - Colima VM started with sensible resource caps
#   - nousresearch/hermes-agent and the sandbox image pre-pulled
#   - ~/.hermes created (left empty for the entrypoint's setup wizard to populate)
#
# It deliberately stops short of running the setup wizard or starting the
# gateway — both are interactive / network-exposing actions you should run
# yourself once this finishes.

set -euo pipefail

COLIMA_CPU="${COLIMA_CPU:-4}"
COLIMA_MEMORY_GB="${COLIMA_MEMORY_GB:-8}"
COLIMA_DISK_GB="${COLIMA_DISK_GB:-80}"
# vz uses Apple's Virtualization.framework (fast; Apple Silicon).
# qemu is the slow fallback for Intel Macs or when vz is unavailable.
COLIMA_VM_TYPE="${COLIMA_VM_TYPE:-vz}"
COLIMA_PROFILE="${COLIMA_PROFILE:-default}"
HERMES_IMAGE="${HERMES_IMAGE:-nousresearch/hermes-agent:latest}"
HERMES_SANDBOX_IMAGE="${HERMES_SANDBOX_IMAGE:-nikolaik/python-nodejs:python3.11-nodejs20}"

# Hermes profile name. Each profile is an independent agent (its own SOUL,
# skills, memory, sessions, credentials) backed by its own host data dir and
# its own container. Run this script once per profile.
HERMES_PROFILE_NAME="${HERMES_PROFILE_NAME:-default}"

if [[ "$HERMES_PROFILE_NAME" == "default" ]]; then
    HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
    HERMES_GATEWAY_NAME="${HERMES_GATEWAY_NAME:-hermes}"
    HERMES_DASHBOARD_NAME="${HERMES_DASHBOARD_NAME:-hermes-dashboard}"
else
    HERMES_HOME="${HERMES_HOME:-$HOME/.hermes-$HERMES_PROFILE_NAME}"
    HERMES_GATEWAY_NAME="${HERMES_GATEWAY_NAME:-hermes-$HERMES_PROFILE_NAME}"
    HERMES_DASHBOARD_NAME="${HERMES_DASHBOARD_NAME:-hermes-dashboard-$HERMES_PROFILE_NAME}"
fi
HERMES_GATEWAY_PORT="${HERMES_GATEWAY_PORT:-8642}"
HERMES_DASHBOARD_PORT="${HERMES_DASHBOARD_PORT:-9119}"
HERMES_NETWORK="${HERMES_NETWORK:-hermes-net-$HERMES_PROFILE_NAME}"

echo "=== Hermes host bootstrap ==="
echo "  Colima profile   : $COLIMA_PROFILE"
echo "  Colima resources : $COLIMA_CPU CPU / ${COLIMA_MEMORY_GB} GB RAM / ${COLIMA_DISK_GB} GB disk"
echo "  Colima vm-type   : $COLIMA_VM_TYPE"
echo "  Hermes image     : $HERMES_IMAGE"
echo "  Hermes profile   : $HERMES_PROFILE_NAME"
echo "  Hermes data dir  : $HERMES_HOME (host) -> /opt/data (container)"
echo "  Gateway container: $HERMES_GATEWAY_NAME (port $HERMES_GATEWAY_PORT)"
echo "  Dashboard cont.  : $HERMES_DASHBOARD_NAME (port $HERMES_DASHBOARD_PORT)"
echo "  Docker network   : $HERMES_NETWORK"
echo

if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: this script targets macOS." >&2
    exit 1
fi

# 1. Homebrew --------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
    echo "Installing Homebrew (non-interactive)..."
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if ! command -v brew >/dev/null 2>&1; then
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    else
        echo "Error: Homebrew install reported success but 'brew' is not on PATH." >&2
        exit 1
    fi
fi

# 2. Container runtime ----------------------------------------------------
echo "Installing colima, docker CLI, docker-compose..."
brew install colima docker docker-compose

# 3. Colima ---------------------------------------------------------------
if colima status -p "$COLIMA_PROFILE" >/dev/null 2>&1; then
    echo "Colima profile '$COLIMA_PROFILE' is already running."
else
    echo "Starting Colima (vm-type=$COLIMA_VM_TYPE)..."
    if ! colima start -p "$COLIMA_PROFILE" \
        --vm-type "$COLIMA_VM_TYPE" \
        --cpu "$COLIMA_CPU" \
        --memory "$COLIMA_MEMORY_GB" \
        --disk "$COLIMA_DISK_GB"; then
        cat >&2 <<EOF

Colima failed to start with --vm-type=$COLIMA_VM_TYPE.
On Intel Macs (or if vz is unavailable) retry with QEMU:

    COLIMA_VM_TYPE=qemu $0
EOF
        exit 1
    fi
fi

# 4. Verify daemon --------------------------------------------------------
echo "Verifying docker..."
docker version >/dev/null
docker info >/dev/null

# 5. Pre-pull images ------------------------------------------------------
echo "Pulling Hermes image: $HERMES_IMAGE"
docker pull "$HERMES_IMAGE"

# Sandbox image used when terminal.backend = docker (nested DinD). Pulled now
# so the first chat doesn't have to wait on it. Cheap if unused.
echo "Pulling sandbox image: $HERMES_SANDBOX_IMAGE"
docker pull "$HERMES_SANDBOX_IMAGE"

# 6. Create the data dir (entrypoint will populate it on first 'setup' run) -
mkdir -p "$HERMES_HOME"
chmod 700 "$HERMES_HOME"

# 7. Docker network so the dashboard can reach the gateway by container name -
if ! docker network inspect "$HERMES_NETWORK" >/dev/null 2>&1; then
    echo "Creating docker network: $HERMES_NETWORK"
    docker network create "$HERMES_NETWORK" >/dev/null
fi

cat <<EOF

=== Done ===
Next steps (profile: $HERMES_PROFILE_NAME, data: $HERMES_HOME):

  1. Run the Hermes setup wizard (interactive; writes ~/.hermes/.env and
     copies the default config.yaml on first run):
       docker run -it --rm \\
         -v $HERMES_HOME:/opt/data \\
         $HERMES_IMAGE setup

  2. After the wizard, harden $HERMES_HOME/config.yaml:
       - terminal.docker_forward_env: []          (empty)
       - terminal.container_persistent: false     (ephemeral)
       - terminal.docker_mount_cwd_to_workspace: false
       - approvals.mode: manual
     Edit directly or use 'hermes config set …' inside a one-shot container.
     Then restrict the credentials file:
       chmod 600 $HERMES_HOME/.env

  3a. Open an interactive chat:
       docker run -it --rm \\
         -v $HERMES_HOME:/opt/data \\
         --memory 4g --cpus 2 --shm-size 1g \\
         $HERMES_IMAGE

  3b. Run the messaging gateway as a daemon (port $HERMES_GATEWAY_PORT):
       docker run -d --name $HERMES_GATEWAY_NAME --restart unless-stopped \\
         --network $HERMES_NETWORK \\
         -v $HERMES_HOME:/opt/data \\
         -p $HERMES_GATEWAY_PORT:8642 \\
         --memory 4g --cpus 2 --shm-size 1g \\
         $HERMES_IMAGE gateway run

  3c. (Optional) Run the web dashboard alongside the gateway (port $HERMES_DASHBOARD_PORT):
       docker run -d --name $HERMES_DASHBOARD_NAME --restart unless-stopped \\
         --network $HERMES_NETWORK \\
         -v $HERMES_HOME:/opt/data \\
         -p $HERMES_DASHBOARD_PORT:9119 \\
         -e GATEWAY_HEALTH_URL=http://$HERMES_GATEWAY_NAME:8642 \\
         $HERMES_IMAGE dashboard --host 0.0.0.0
     Then open http://localhost:$HERMES_DASHBOARD_PORT.
     (--host 0.0.0.0 is required so the dashboard binds outside the
     container's loopback; without it, the published port has no listener.)
     Warning: do not expose either port on an internet-facing host.

Multi-profile pattern (one container set per profile, each with its own host
data dir — see https://hermes-agent.nousresearch.com/docs/user-guide/docker#multi-profile-support):

       HERMES_PROFILE_NAME=work     HERMES_GATEWAY_PORT=8642 HERMES_DASHBOARD_PORT=9119 ./hermes-setup.sh
       HERMES_PROFILE_NAME=personal HERMES_GATEWAY_PORT=8643 HERMES_DASHBOARD_PORT=9120 ./hermes-setup.sh

Reference: https://hermes-agent.nousresearch.com/docs/user-guide/docker
EOF
