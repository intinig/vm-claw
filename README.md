# vm-claw

Run [Hermes Agent](https://hermes-agent.nousresearch.com/) on a macOS host with a
sidecar Tart VM that hosts iMessage under a **separate Apple ID**, so the agent can
send/receive messages without using the host user's iMessage identity.

Two pieces, used together:

- **Hermes on host (Docker via Colima)** — bootstrapped via `vmclaw hermes bootstrap`,
  following the [Hermes Docker user guide](https://hermes-agent.nousresearch.com/docs/user-guide/docker).
- **iMessage bridge VM (Tart)** — managed via `vmclaw vm <verb>`, a macOS guest
  with its own user, its own Apple ID, Messages.app signed in, and
  [BlueBubbles Server](https://bluebubbles.app/downloads/server/) exposing the bridge protocol
  Hermes calls.

See the [design spec](./docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md)
for the full design, including why a VM (vs. a second host user) and the migration
plan.

## Hermes — host side (Docker)

Hermes runs **inside the `nousresearch/hermes-agent` container**, with `~/.hermes` on
the host bind-mounted to `/opt/data` inside the container. Colima provides the Docker
daemon.

### Hardening to apply after the setup wizard

The wizard writes a default `~/.hermes/config.yaml`. Edit it (or use `hermes config set`
inside a one-shot container) so the following hold:

- `terminal.container_persistent: false` — ephemeral tmpfs sandbox, wiped on teardown.
- `terminal.docker_forward_env: []` — host env never auto-forwarded; credentials reach
  a sandbox only via skill-declared `required_environment_variables`.
- `terminal.docker_mount_cwd_to_workspace: false` — explicit, scoped volumes only.
- `approvals.mode: manual` — dangerous commands prompt. Required for the iMessage
  skill so sends are user-approved.

(These take effect when `terminal.backend: docker`; harmless under the default `local`
backend.)

### Requirements

- macOS host (Apple Silicon recommended for Colima `--vm-type vz`).
- Network access to Docker Hub.

### Usage

```bash
make install          # build + install vmclaw to ~/go/bin
vmclaw bootstrap      # creates VM, bootstraps Hermes, installs LaunchAgent,
                      # generates webhook secret, prints Phase 2 runbook
```

`vmclaw bootstrap` (internally `vmclaw hermes bootstrap`) installs Homebrew (if
missing), `colima`, the `docker` CLI, and `docker-compose`; starts the Colima VM;
pre-pulls `nousresearch/hermes-agent` and the inner sandbox image; creates
`~/.hermes`; and creates a docker network for the gateway/dashboard pair to share.
It prints next-step commands tailored to the chosen profile.

Tunables (env vars):

| Var | Default | Notes |
|---|---|---|
| `COLIMA_CPU` | `4` | vCPUs for the Colima VM |
| `COLIMA_MEMORY_GB` | `8` | RAM for the Colima VM |
| `COLIMA_DISK_GB` | `80` | Disk for the Colima VM |
| `COLIMA_VM_TYPE` | `vz` | `vz` on Apple Silicon, fall back to `qemu` on Intel |
| `COLIMA_PROFILE` | `default` | Colima profile name |
| `HERMES_IMAGE` | `nousresearch/hermes-agent:latest` | Hermes container image |
| `HERMES_PROFILE_NAME` | `default` | Hermes profile (see Multi-profile below) |
| `HERMES_HOME` | `$HOME/.hermes` (or `$HOME/.hermes-<profile>`) | Host data dir → `/opt/data` |
| `HERMES_GATEWAY_NAME` | `hermes` (or `hermes-<profile>`) | Gateway container name |
| `HERMES_DASHBOARD_NAME` | `hermes-dashboard` (or `hermes-dashboard-<profile>`) | Dashboard container name |
| `HERMES_GATEWAY_PORT` | `8642` | Host port for the gateway |
| `HERMES_DASHBOARD_PORT` | `9119` | Host port for the dashboard |
| `HERMES_NETWORK` | `hermes-net-<profile>` | Docker network shared by gateway + dashboard |

After the script finishes:

```bash
# 1. Run the Hermes setup wizard (interactive — writes ~/.hermes/.env and the
#    default ~/.hermes/config.yaml)
docker run -it --rm \
  -v ~/.hermes:/opt/data \
  nousresearch/hermes-agent setup

# 2. Apply the hardening listed above by editing ~/.hermes/config.yaml.

# 3a. Open an interactive chat
docker run -it --rm \
  -v ~/.hermes:/opt/data \
  --memory 4g --cpus 2 --shm-size 1g \
  nousresearch/hermes-agent

# 3b. Run the messaging gateway as a daemon (port 8642)
docker run -d --name hermes --restart unless-stopped \
  --network hermes-net-default \
  -v ~/.hermes:/opt/data \
  -p 8642:8642 \
  --memory 4g --cpus 2 --shm-size 1g \
  nousresearch/hermes-agent gateway run

# 3c. (Optional) Web dashboard alongside the gateway (port 9119)
#     --host 0.0.0.0 is required: the dashboard binds to 127.0.0.1 inside the
#     container by default, so a published port has no listener without it.
docker run -d --name hermes-dashboard --restart unless-stopped \
  --network hermes-net-default \
  -v ~/.hermes:/opt/data \
  -p 9119:9119 \
  -e GATEWAY_HEALTH_URL=http://hermes:8642 \
  nousresearch/hermes-agent dashboard --host 0.0.0.0
# Open http://localhost:9119
```

`--shm-size 1g` is needed for Playwright/Chromium browser tools.

Don't expose `8642` or `9119` on an internet-facing host.

### Multi-profile pattern

Hermes supports multiple independent agents (separate SOUL, skills, memory, sessions,
credentials) by giving each its own host data dir and its own container set
([upstream guidance](https://hermes-agent.nousresearch.com/docs/user-guide/docker#multi-profile-support)).
Run the setup script once per profile with distinct names and ports:

```bash
HERMES_PROFILE_NAME=work \
  HERMES_GATEWAY_PORT=8642 HERMES_DASHBOARD_PORT=9119 \
  vmclaw hermes bootstrap

HERMES_PROFILE_NAME=personal \
  HERMES_GATEWAY_PORT=8643 HERMES_DASHBOARD_PORT=9120 \
  vmclaw hermes bootstrap
```

Each invocation creates `~/.hermes-<profile>/`, a `hermes-net-<profile>` docker
network, and prints next-step commands with `hermes-<profile>` /
`hermes-dashboard-<profile>` container names. **Never run two gateways against the
same data dir** — session/memory stores aren't designed for concurrent writes.

## iMessage bridge VM — Tart

A Tart-based macOS VM bridged onto the host's LAN interface. Inside the guest, a
dedicated user is signed in to a **separate Apple ID** with iMessage enabled, and a
small bridge service exposes a host-reachable API that Hermes calls.

> ### Networking: bridged-mode workaround for the Tahoe vmnet regression
>
> vm-claw originally used Tart's `--net-softnet` for an isolated NAT'd guest
> network, configurable via `Shared_Net_Address` in
> `/Library/Preferences/SystemConfiguration/com.apple.vmnet.plist`. That key is
> **silently ignored on macOS 26 (Tahoe)** — `bridge100` ends up on
> `192.168.2.0/24` regardless, which collides with many home routers. We've
> temporarily switched to `--net-bridged=<iface>` (auto-detected via the IPv4
> default route, override with `BRIDGE_HOST_IFACE`). The VM lives on your home
> LAN directly, so isolation is weaker — don't run this on an untrusted shared
> network. We'll revert to softnet once the regression is fixed.
>
> Track upstream:
> - [canonical/multipass#4383](https://github.com/canonical/multipass/issues/4383)
>   — original Tahoe regression report; same root cause.
> - [canonical/multipass#4581](https://github.com/canonical/multipass/issues/4581)
>   — duplicate; confirms `Shared_Net_Address` no longer honored.
> - [apple/container#109](https://github.com/apple/container/issues/109)
>   — same bug hits Apple's own `container` tool.
> - [cirruslabs/tart discussion #1092](https://github.com/cirruslabs/tart/discussions/1092)
>   — Tart maintainer notes `Shared_Net_Address` works on Sequoia 15.5; the
>   break is Tahoe-specific. Watch for a Tart-side workaround.
> - [Tart FAQ — changing the default NAT subnet](https://tart.run/faq/) — what
>   the documented config knob looks like (the one Tahoe ignores).
> - [canonical/multipass PR #4686](https://github.com/canonical/multipass/pull/4686)
>   — multipass's QEMU-layer workaround. Doesn't apply directly to Tart
>   (Virtualization.framework, not QEMU), but shows the shape of a fix.

### Why a VM

iMessage is bound to the Apple ID of the logged-in macOS user. A second user on the
host works in theory but Messages.app behaves poorly when fast-user-switched to the
background, and it puts a second identity on the same login session as your real
keychain and mail. A VM gives the bridge identity its own login, keychain, trusted
devices, and Messages history. See the
[design spec](./docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md#why-a-vm-rather-than-a-second-host-user).

### Isolation

- **Bridged onto the host LAN (current — Tahoe stopgap)** — guest gets a DHCP
  lease from the LAN router. No NAT between host and guest; both reach each
  other over the LAN. BlueBubbles is reachable by every device on the LAN, so
  the BlueBubbles password is the only access control.
- **No host secrets shared** — host's Apple ID stays on the host; the VM uses an
  Apple ID created for this purpose.

### Requirements

```bash
brew install cirruslabs/cli/tart
```

Plus a trusted device for the bridge Apple ID's 2FA the first time.

(`cirruslabs/cli/softnet` is no longer required while we're on the bridged-mode
workaround. Reinstall it when reverting to `--net-softnet`.)

### Usage

```bash
make install              # build + install vmclaw to ~/go/bin
vmclaw bootstrap          # creates VM, bootstraps Hermes, installs LaunchAgent,
                          # generates webhook secret, prints Phase 2 runbook
# ...do Phase 2 manually inside the VM (Apple ID, Messages.app,
# BlueBubbles install + webhook config — see docs/superpowers/specs/...)
vmclaw bootstrap finalize # writes ~/.hermes/.env, restarts Hermes gateway,
                          # runs doctor
vmclaw doctor             # spot-check anytime
vmclaw vm destroy --yes   # tear down the VM (e.g., to rebuild from scratch)
```

After first boot, the VM needs manual setup before Hermes can use it. The full
runbook is in the
[design spec](./docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md#vm-provisioning-runbook);
the short version:

1. Create the dedicated `bridge` macOS user, set it to auto-login.
2. Sign in to a fresh Apple ID. Complete 2FA (needs a trusted device).
3. Enable iMessage in Messages.app, verify a test message arrives.
4. Install BlueBubbles Server, grant Full Disk Access + Automation, set the
   admin password, configure the webhook to Hermes' gateway.
5. Add BlueBubbles Server to Login Items so it launches with the GUI session.

## License

MIT
