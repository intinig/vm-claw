# vm-claw

Self-host the [OpenClaw](https://openclaw.ai) AI agent on macOS, with a dedicated Apple ID for iMessage interop, inside a Sequoia (macOS 15) VM. Tailscale gates the only network path in.

## What this is

- A Tart-managed macOS Sequoia VM (`vm-claw`) that runs OpenClaw + Messages.app + Tailscale.
- A tiny Go CLI (`vmclaw`) on the host that creates/runs the VM, installs Tailscale inside it, and runs an end-to-end `doctor`.
- A manual runbook that you follow once per VM rebuild to install OpenClaw and configure it.

## Why

- Keep your personal Apple ID untouched — the VM signs in to a separate one for iMessage.
- The agent is invisible on your LAN — Tailscale-only inbound, macOS Application Firewall default-deny.
- Sequoia avoids the macOS 26 (Tahoe) iMessage regressions that hit `openclaw/imsg`.

## Prerequisites

- Apple Silicon Mac on macOS Tahoe (host).
- [Tart](https://tart.run) installed (`brew install cirruslabs/cli/tart`).
- A Tailscale account and a reusable / ephemeral [auth key](https://tailscale.com/kb/1085/auth-keys/).
- A separate Apple ID dedicated to this VM. Do not use your personal one.
- ~80 GB free disk for the VM.

## Quickstart

```bash
# Build and install the CLI
make install

# Create the Sequoia VM, install LaunchAgent, wait for IP
vmclaw bootstrap

# Inside the VM GUI window: sign into the bridge Apple ID, enable iMessage.
# (One-time manual step. ~5 minutes.)

# Install Tailscale inside the VM and lock down the firewall
echo 'tskey-auth-...' > /tmp/ts.key && chmod 600 /tmp/ts.key
vmclaw vm tailscale-bootstrap --auth-key-file=/tmp/ts.key
rm /tmp/ts.key

# Follow the manual runbook to install OpenClaw, imsg, and config
open docs/runbook-openclaw-install.md

# Verify the whole chain
vmclaw doctor
```

## Networking: bridged-mode workaround for the Tahoe vmnet regression

The VM is launched with `--net-bridged=<iface>` where `<iface>` is the host's default-route interface (auto-detected via `DetectBridgeInterface`; override via `BRIDGE_HOST_IFACE`). This is a workaround for a confirmed Tahoe vmnet regression that broke softnet's `Shared_Net_Address`. Once upstream ships a fix, revert to `--net-softnet`.

Bridged-mode does NOT expose OpenClaw on the LAN: macOS Application Firewall default-denies inbound + nothing binds `0.0.0.0`. Only Tailscale gets through.

## Inside-VM OpenClaw setup

See [`docs/runbook-openclaw-install.md`](./docs/runbook-openclaw-install.md) for the full manual runbook (Node 24 install, OpenClaw npm install, imsg brew install, Full Disk Access, OpenClaw config from sample, gateway LaunchAgent).

## Troubleshooting

See the "Recovery paths" section of [`CLAUDE.md`](./CLAUDE.md).

## Project history

This was originally a Hermes-agent project that ran the agent in Docker on the host with a Tahoe bridge VM for iMessage relay (BlueBubbles). It pivoted to OpenClaw-in-Sequoia-VM after the Hermes BlueBubbles adapter went unfixed upstream and macOS Tahoe introduced iMessage path regressions. The original spec lives at [`docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md`](./docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md) and is marked superseded. The current spec is [`docs/superpowers/specs/2026-05-25-openclaw-sequoia-vm-design.md`](./docs/superpowers/specs/2026-05-25-openclaw-sequoia-vm-design.md).
