# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This project hosts [Hermes Agent](https://hermes-agent.nousresearch.com/) on a macOS
host (in Docker via Colima) and pairs it with a single-purpose **iMessage bridge VM**
(Tart) so the agent can send/receive iMessage under an Apple ID **distinct** from the
host user's. Hermes itself does not run inside the VM — the VM exists only to host
the second Apple identity and the Messages.app stack that goes with it.

Two components, used **together** (not independent paths):

1. **Hermes on host** (`hermes-setup.sh`) — bootstraps Colima + docker, runs the
   `nousresearch/hermes-agent` container with `~/.hermes` bind-mounted to `/opt/data`.
   Following [the Hermes Docker user guide](https://hermes-agent.nousresearch.com/docs/user-guide/docker).
2. **iMessage bridge VM** (`setup.sh` / `run.sh` / `destroy.sh`) — Tart-based macOS
   guest, softnet networking, one dedicated user signed in to the bridge Apple ID.
   Inside, a bridge service exposes an API Hermes calls.

The VM is **not** an isolation boundary for Hermes (Hermes is already containerized
and is trusted relative to this project). The VM exists to give iMessage a clean,
separate identity.

This repo previously scoped a Tart VM for [OpenClaw](https://openclaw.ai). That scope
is retired. Some scripts still use the `openclaw` VM name pending migration; treat
that as known-stale, not a directive. Authoritative current direction lives in
[`docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md`](./docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md).

## Hermes-Path Configuration Constraints

`hermes-setup.sh` deliberately does **not** seed `~/.hermes/config.yaml` — the
container entrypoint copies the default on the first `setup` run (this is the
upstream-documented flow). Hardening is applied by the user afterward, by editing
the file or via `hermes config set`.

When editing `~/.hermes/config.yaml`, preserve these values — they are the security
contract:

- `terminal.docker_forward_env: []` — keep empty. Credentials reach any sandbox only
  via skill-declared `required_environment_variables` (auto-forwarded since Hermes
  v0.5.1).
- `terminal.container_persistent: false` — ephemeral tmpfs sandbox; persistent state
  belongs in skill outputs the agent writes back explicitly, not in the container
  filesystem.
- `terminal.docker_mount_cwd_to_workspace: false` — explicit `docker_volumes` only,
  prefer `:ro`.
- `approvals.mode: manual` — keep prompts on for dangerous commands. **Required**
  for the iMessage skill so sends are user-approved (a compromised Hermes could
  otherwise send arbitrary messages from the bridge identity).

These keys are meaningful when `terminal.backend` is `docker` (nested DinD inside
the Hermes container). Under the default `local` backend the Hermes container itself
is the sandbox and the keys are inert — apply them anyway so any future switch is
safe by default.

When invoking `docker run` for the Hermes container, do **not** pass arbitrary `-e`
flags from the surrounding shell environment. Provider keys should sit in
`~/.hermes/.env` (chmod 600); the entrypoint loads them. Extra `-e` flags should be
limited to what the docs explicitly document (e.g. `GATEWAY_HEALTH_URL` for the
dashboard container).

## Hermes-Path Multi-Profile

Multiple independent agents per host
([upstream pattern](https://hermes-agent.nousresearch.com/docs/user-guide/docker#multi-profile-support)).
Knobs (env vars consumed by `hermes-setup.sh`):

- `HERMES_PROFILE_NAME` — profile name. Default `default`. Drives the defaults below.
- `HERMES_HOME` — host data dir. Default `~/.hermes` for `default`, else
  `~/.hermes-<profile>`.
- `HERMES_GATEWAY_NAME` / `HERMES_DASHBOARD_NAME` — container names. Default
  `hermes` / `hermes-dashboard` for `default`, else `hermes-<profile>` /
  `hermes-dashboard-<profile>`.
- `HERMES_GATEWAY_PORT` (default `8642`) / `HERMES_DASHBOARD_PORT` (default `9119`).
- `HERMES_NETWORK` — docker network shared by the gateway+dashboard pair. Default
  `hermes-net-<profile>`.

Run the script once per profile with distinct ports. Never run two gateway
containers against the same data dir — session/memory stores aren't designed for
concurrent writes.

Note: the iMessage bridge VM is bound to the Apple ID inside it, so a single bridge
VM can only serve one iMessage identity. If multiple Hermes profiles need iMessage
under different identities, plan for one bridge VM per identity.

## iMessage Bridge VM Requirements

The Tart VM must enforce:

- **softnet networking** — its own NAT, no leakage of the host's VPN/routes into
  the guest. The bridge service binds only on the softnet-side interface; no
  internet-facing exposure.
- **Distinct Apple ID** — never sign the bridge VM into the host user's Apple ID.
  Use a fresh Apple ID created for this purpose. iMessage in a VM is a grey area
  with Apple; do not put a personal account at risk.
- **GUI session always active** — Messages.app does not run from a background
  launchd context. The bridge service must be a LaunchAgent under the bridge user
  (not a LaunchDaemon), and the user must auto-login at boot.

Clipboard sharing left enabled for usability. The read-only shared folder from the
former OpenClaw scope is no longer load-bearing for security; if used at all it is
for one-off file hand-offs.

## Bridge Transport

Hermes-on-host talks to the bridge VM via [BlueBubbles Server](https://bluebubbles.app/server/),
which runs inside the VM. Hermes' first-party BlueBubbles connector handles both
sends (Hermes → BlueBubbles REST) and receives (BlueBubbles webhook → Hermes
gateway). No custom skill, no custom shim. Network plumbing details (host
loopback `socat` forward, softnet gateway path) live in the
[design spec](./docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md#network-model).

## Tart Commands Reference

```bash
# Create a macOS VM from IPSW or restore image
tart create <vm-name> --from-ipsw <path>

# Clone from a base image
tart clone <source> <vm-name>

# Run VM with options
tart run <vm-name> --net-softnet --dir=shared:~/path/to/shared:ro

# List VMs
tart list

# Delete VM
tart delete <vm-name>
```

## Key Tart Flags for Isolation

- `--net-softnet` — Routes VM traffic through Cirrus' softnet helper, giving the
  guest its own NAT independent of the host's network stack (so host VPN/routes do
  not leak into the guest). The default `tart run` networking is shared vmnet,
  which DOES inherit the host's routes — do not rely on it.
- `--dir=<name>:<host-path>:ro` — Mounts read-only shared folder. Optional in the
  current scope; not load-bearing.

## Architecture

Shell-script based project. Expected structure:

- `hermes-setup.sh` — Colima + Hermes-image bootstrap (host side).
- `setup.sh` / `run.sh` / `destroy.sh` — Tart VM lifecycle for the iMessage bridge
  VM. Currently still uses the `openclaw` VM name from the previous scope; rename
  is tracked in the design spec.
- `~/.hermes` — host-side dir bind-mounted into the Hermes container as `/opt/data`.
- `docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md` — design,
  decisions log, migration plan. Authoritative for current direction.
