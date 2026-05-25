# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This project hosts the [OpenClaw](https://openclaw.ai) AI agent inside a single-purpose **macOS Sequoia (15.x) VM** (Tart), network-isolated to a Tailscale tailnet, signed into an Apple ID **distinct** from the host user's. The VM IS the agent host — OpenClaw, Messages.app, Tailscale daemon all run inside it.

Two components, used **together**:

1. **Sequoia Tart VM** (`vm-claw`) — runs OpenClaw natively (`npm install -g openclaw@latest`), Messages.app signed into the bridge Apple ID, and the Tailscale daemon. Bridged networking on the host's default-route interface (Tahoe vmnet stopgap). macOS Application Firewall set to default-deny inbound.
2. **`vmclaw` CLI on host** (Go binary in this repo) — VM lifecycle (`vmclaw vm create | run | destroy | install-agent`), Tailscale install + firewall lockdown (`vmclaw vm tailscale-bootstrap`), and end-to-end `vmclaw doctor`.

The VM is **not** an isolation boundary for OpenClaw itself (the agent is trusted relative to this project — it's the user's agent). The VM provides:
- A separate Apple ID for iMessage, never the host user's.
- A clean macOS Sequoia runtime, avoiding macOS 26 (Tahoe) iMessage regressions: `openclaw/imsg#90` (group send silent fail), LaunchAgent Full Disk Access propagation, FSEvents coalescing.
- A Tailscale-only inbound boundary, so the agent is invisible on the LAN.

Authoritative direction lives in [`docs/superpowers/specs/2026-05-25-openclaw-sequoia-vm-design.md`](./docs/superpowers/specs/2026-05-25-openclaw-sequoia-vm-design.md).

## OpenClaw Configuration Constraints

`docs/openclaw-config.example.yaml` is the canonical template for `~/.openclaw/config.yaml` inside the VM. When editing, preserve these values — they are the security contract:

- `auth.required: true` — WebChat / API auth token required even on tailnet (defense in depth).
- `permissions.askConfirmation: true` — manual approvals for sensitive actions; equivalent of the old `approvals.mode: manual`.
- `terminal.persistent: false` — ephemeral sandbox; no state leak across invocations.
- No `terminal.workspaceMount` — do not bind-mount host paths.
- `plugins.allowList: [...]` populated; `plugins.autoInstall: false`. Mitigates ClawHavoc-class supply-chain risk. Add plugins by exact name; no wildcards.
- `channels.imessage.dmPolicy: allowlist` + `channels.imessage.groupPolicy: allowlist` with explicit allowlists; never `open`.
- `channels.imessage.groups["*"].requireMention: true` — bot replies only on @-mention or configured `mentionPatterns`.
- Provider keys live directly in `config.yaml` (`chmod 600`, owned by the bridge user). No env injection from outside the VM.

## Network Posture

- **Inbound to VM:** Tailscale-only. OpenClaw WebChat binds to `127.0.0.1` (Tailscale Serve forwards from tailnet) or `tailscale0`. Nothing binds `0.0.0.0`. macOS Application Firewall default-denies all incoming on bridged + loopback interfaces.
- **Outbound from VM:** **Unrestricted by design.** An AI agent with restricted outbound is useless. Tailscale ACLs do not restrict outbound; the macOS firewall is inbound-only. Do not propose outbound allowlists — see `~/.claude/projects/-Users-gintini-s-vm-claw/memory/feedback_agent_outbound_unrestricted.md`.
- **Tailnet ACL:** inbound to `tag:vm-claw` allowed only from the user's tagged devices. No outbound ACL rules.

## Apple ID Discipline

- Never sign the VM into the host user's Apple ID. Use a separate Apple ID dedicated to vm-claw.
- iMessage in a VM is a grey area with Apple; do not put a personal account at risk.
- The bridge Apple ID is portable across rebuilds; only local Messages history and skill/memory state are lost on `vmclaw vm destroy`.

## GUI session always active

Messages.app does not run from a background launchd context. The bridge service must run as a LaunchAgent under the bridge user (not a LaunchDaemon), and the user must auto-login at boot. This applies to OpenClaw's gateway too (`openclaw onboard --install-daemon` writes a LaunchAgent).

## Networking: bridged-mode workaround for the Tahoe vmnet regression

The VM is launched with `--net-bridged=<iface>` where `<iface>` is the host's default-route interface (auto-detected via `DetectBridgeInterface`; override via `BRIDGE_HOST_IFACE`).

This is a workaround for a confirmed macOS Tahoe regression that broke the `Shared_Net_Address` config key for `--net-softnet`/vmnet shared mode. softnet remains the long-term goal once Apple/Cirrus ship a fix; revert by flipping the `tart run` flag and the LaunchAgent plist back to `--net-softnet`.

Bridged-mode caveat that USED TO matter under Hermes-era BlueBubbles is now neutralized: the VM exposes no inbound services on the LAN because of the macOS Application Firewall default-deny + Tailscale-only binding. Even on a hostile LAN, the only thing reachable on the VM is ARP/ping.

## Tart Commands Reference

```bash
# Clone from Cirrus OCI base image
tart clone ghcr.io/cirruslabs/macos-sequoia-base@sha256:<digest> vm-claw

# Run VM with bridged networking
tart run vm-claw --net-bridged=en0

# List VMs and base images
tart list

# Get VM IP
tart ip vm-claw

# Exec inside VM (uses guest SSH automatically)
tart exec vm-claw -- /usr/bin/sw_vers -productVersion

# Delete VM
tart delete vm-claw
```

## Key Tart Flags for Isolation

- `--net-bridged=<iface>` — current setting; bridges VM onto `<iface>` (host's default-route interface). The VM gets a DHCP lease from the LAN router. Tahoe-host stopgap until vmnet softnet regression is fixed.
- `--net-softnet` — original setting (no longer used). Will return once Apple/Cirrus fix vmnet.
- No `--dir` shared folders are needed in the new scope; use Tailscale SCP for file hand-offs.

## Recovery paths

When something silently breaks, work down this list before deeper debugging:

1. **`vmclaw doctor`** — green/red status across the chain.
2. **VM not booting / no IP** — `tart list` and `tart ip vm-claw`. If the VM exists but has no IP, run `vmclaw vm run`, or `vmclaw vm install-agent` to load the LaunchAgent. Bridged DHCP comes from your LAN router.
3. **Wrong bridge interface picked up** — auto-detect uses the IPv4 default route; a VPN can hijack it. Override with `BRIDGE_HOST_IFACE=en0 vmclaw vm run` and re-run `vmclaw vm install-agent`.
4. **Host cannot reach VM over Tailscale** — `tailscale status` on host; verify `vm-claw` shows up. Inside VM: `tailscale status` and `tailscale up --reset` if auth expired.
5. **iMessage stops sending** — log into the VM GUI, open Messages.app, confirm iMessage is still active. macOS sleep on the VM is the most common cause; verify "Display sleep when on power adapter" is off.
6. **OpenClaw responding from wrong handle / not responding** — check `~/.openclaw/config.yaml` for `channels.imessage` allowlist drift; check the gateway LaunchAgent is loaded.
7. **Apple ID activation loop** — sign out in Messages (not System Settings), wait 30 s, sign back in. If persistent, recreate the Apple ID; running iMessage in a VM is a grey area with Apple.
8. **VM is unrecoverable / suspect / over-updated** — `vmclaw vm destroy --yes && vmclaw bootstrap`, then re-run `docs/runbook-openclaw-install.md`. The bridge Apple ID is portable; only local Messages history and OpenClaw skill/memory state are lost.
9. **Doctor red on negative connectivity (bridged port unexpectedly reachable)** — firewall is broken. Re-run `vmclaw vm tailscale-bootstrap` to reapply, then doctor again.

## Architecture

Go CLI project. Current structure:

- `cmd/vmclaw/main.go` — entrypoint.
- `internal/cli/` — Cobra subcommands: `bootstrap`, `vm`, `doctor`. No `hermes` subcommand (removed in this rescope).
- `internal/vm/` — Tart wrapper, vmnet collision detection, bridge-interface detection, brew helpers, macOS Application Firewall wrapper, shared `TartExec` for in-VM command execution.
- `internal/tailscale/` — Tailscale install/up/status wrappers over a `vm.Executor` (so they work via `tart exec` inside the VM).
- `internal/launchagent/` — host-side LaunchAgent that auto-starts the VM at login.
- `internal/doctor/` — chain-walking doctor checks.
- `docs/openclaw-config.example.yaml` — canonical OpenClaw config template.
- `docs/runbook-openclaw-install.md` — manual steps to install OpenClaw inside the VM.
- `docs/superpowers/specs/2026-05-25-openclaw-sequoia-vm-design.md` — authoritative spec.
