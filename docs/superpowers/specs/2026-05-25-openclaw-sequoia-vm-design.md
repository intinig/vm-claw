# OpenClaw on Sequoia VM — Design Spec

**Date:** 2026-05-25
**Status:** Draft (pending implementation plan)
**Supersedes:** [`2026-05-04-hermes-imessage-bridge-vm-design.md`](./2026-05-04-hermes-imessage-bridge-vm-design.md)

## Summary

Re-scope `vm-claw` from "Hermes-agent on host + Tahoe iMessage bridge VM" to **"OpenClaw running inside a Sequoia macOS Tart VM, network-isolated to a Tailscale tailnet."**

The VM is no longer a single-purpose bridge for a dedicated Apple ID — it now hosts the entire agent stack (OpenClaw gateway, Messages.app, Tailscale daemon). Access from outside the VM is gated by Tailscale. The host (still macOS Tahoe) runs only the `vmclaw` CLI for VM lifecycle, Tailscale lockdown, and end-to-end doctoring; Colima, Docker, and Hermes are removed from the host entirely.

## Motivation

Two compounding pressures pushed the rescope:

1. **Hermes BlueBubbles adapter is broken upstream and unfixed.** Multiple webhook-path bugs ([hermes-agent#9263](https://github.com/NousResearch/hermes-agent/issues/9263), [#9265](https://github.com/NousResearch/hermes-agent/issues/9265), [#8514](https://github.com/NousResearch/hermes-agent/issues/8514)) block inbound iMessage delivery. Hermes also lacks the group-chat mention-only-respond controls present on its Telegram channel; the equivalent feature request for BlueBubbles isn't even filed.

2. **macOS Tahoe (26) introduces iMessage path regressions.** [`openclaw/imsg#90`](https://github.com/openclaw/imsg/issues/90) reports group sends silently dropped on Tahoe; LaunchAgent Full Disk Access propagation is broken on Tahoe; FSEvents coalescing causes 3-5 minute message delays. macOS 15 (Sequoia) is unaffected — confirmed by upstream: *"imsg continues to function correctly on Sequoia with SIP enabled."*

OpenClaw on Sequoia gives us:
- Group mention gating that already exists (`channels.imessage.groupPolicy` + `agents.list[].groupChat.mentionPatterns`).
- A messaging path (`imsg` over JSON-RPC) that bypasses BlueBubbles entirely.
- A Tahoe-free iMessage runtime in the guest, while the host stays on Tahoe.

The host stays on Tahoe (no migration option there); the vmnet/softnet regression that forced `--net-bridged` continues to apply.

## Architecture

```
                          ┌──────────────────────────────────────────────┐
                          │  Sequoia (macOS 15) Tart VM "vm-claw"        │
   Apple iMessage  ──────►│   ┌──────────────┐                           │
   (push, APNs)           │   │ Messages.app │   chat.db / imsg          │
                          │   │ (bridge      ├─────────► OpenClaw        │
                          │   │  Apple ID)   │           gateway         │
                          │   └──────────────┘           (latest stable) │
                          │                              ▲ ▲             │
                          │   macOS Application Firewall │ │             │
                          │   (default-deny incoming)    │ │             │
                          │   Tailscale daemon ──────────┘ │             │
                          └────────────────────────────────│─────────────┘
                                                           │ tailnet
                                       ┌───────────────────┘
                                       ▼
                                Host (Tahoe) — Tailscale node,
                                Claude Code, vmclaw CLI,
                                browser → OpenClaw WebChat
```

**Components, used together:**

1. **Sequoia Tart VM** (`vm-claw`) — runs Messages.app signed into the bridge Apple ID, the OpenClaw gateway, and the Tailscale daemon. Bridged networking on the host's default-route interface (Tahoe vmnet stopgap). macOS Application Firewall set to default-deny inbound.
2. **Tailscale** — the only path into the VM. OpenClaw's WebChat / MCP / API bind to either `tailscale0` or `127.0.0.1` (then exposed via Tailscale Serve). No service binds to `0.0.0.0`. Tailnet ACL restricts inbound to the user's own tagged devices; outbound is unrestricted.
3. **`vmclaw` CLI on host** — VM lifecycle (`vm create | run | destroy | install-agent`), automated Tailscale install + firewall lockdown (`vm tailscale-bootstrap`), end-to-end doctor (`doctor [--fix]`), and a top-level `bootstrap` that orchestrates create → install-agent → run → tailscale-bootstrap. OpenClaw setup inside the VM is a manual runbook (documented in README), not automated by vmclaw.

**Out of scope for vm-claw:**
- Hermes (removed).
- Colima / Docker on host (removed).
- BlueBubbles (removed; the imsg path replaces it).
- Automated OpenClaw install inside the VM (manual runbook).

## Components — code restructure

### Deleted (Hermes-era)

- `internal/hermes/` package directory (colima.go, docker.go, envfile.go, envfile_test.go).
- `internal/cli/hermes.go` — `vmclaw hermes …` subcommand wiring.
- Hermes refs in `internal/cli/bootstrap.go` and `internal/cli/root.go`.

### Kept, retargeted

- `cmd/vmclaw/main.go` — entrypoint, unchanged.
- `internal/cli/root.go` — drop `hermes` subcommand wiring, add `vm tailscale-bootstrap`.
- `internal/cli/bootstrap.go` — `vmclaw bootstrap` becomes: create VM (Sequoia IPSW) → install LaunchAgent → run → tailscale-bootstrap → print runbook pointer for manual OpenClaw install.
- `internal/cli/vm.go` — `vm create/run/destroy/install-agent`, IPSW default switched to Sequoia.
- `internal/cli/doctor.go` — same CLI surface, replaced checks.
- `internal/vm/tart.go` + test — IPSW pin logic; Sequoia 15.x default.
- `internal/vm/vmnet.go` + test — Tahoe-host vmnet workaround unchanged.
- `internal/vm/bridge_iface.go` — bridge interface auto-detect unchanged.
- `internal/vm/exec.go` — `tart exec` / SSH plumbing, exercised heavily by Tailscale automation.
- `internal/launchagent/plist.go` + test + template — `--net-bridged` LaunchAgent generic; the VM name is templated (was `bridge-vm`, becomes `vm-claw`).
- `internal/doctor/checks.go` — replaced Hermes/Colima checks with OpenClaw/Tailscale/firewall checks.

### New

- `internal/tailscale/setup.go` — installs Tailscale inside the VM via SSH (`brew install --cask tailscale` or standalone PKG), starts the daemon, runs `tailscale up --auth-key=…`, verifies node joined the tailnet. Auth key is consumed once and never logged.
- `internal/vm/firewall.go` — wraps `/usr/libexec/ApplicationFirewall/socketfilterfw` invocations to set "block all incoming" mode and verify Tailscale daemon is in the allowed-apps list.
- `internal/cli/tailscale.go` — wires `vmclaw vm tailscale-bootstrap [--auth-key=… | --auth-key-file=…]`.

### Project-level

- `Makefile`, `go.mod`, `go.sum` — minor cleanup (Hermes-only imports removed).
- README.md — full rewrite.
- CLAUDE.md — full rewrite.
- `docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md` — leave in place as archaeology; add a `**Superseded by:** 2026-05-25-openclaw-sequoia-vm-design.md` header at top.

## Security Surface Mapping

Old security contract was defined against Hermes-in-Docker. Re-expressed against OpenClaw-on-macOS below.

| Old (Hermes era) | New (OpenClaw + Sequoia VM) |
|---|---|
| Apple ID isolation — distinct VM identity | Unchanged. Reuse the existing bridge Apple ID; still never the host user's. |
| `terminal.docker_forward_env: []` | OpenClaw runs native, not DinD. Equivalent: provider keys live only in `~/.openclaw/config.yaml` (`chmod 600`) inside the VM. Host shell env never reaches the VM (vmclaw doesn't pass env through). |
| `terminal.container_persistent: false` | `terminal.persistent: false` in OpenClaw config — direct key-name mapping. |
| `terminal.docker_mount_cwd_to_workspace: false` | OpenClaw doesn't auto-mount host paths. Verify `terminal.workspaceMount` is unset. |
| `approvals.mode: manual` | OpenClaw `permissions.askConfirmation: true` globally + iMessage channel uses the per-message approval flow (`👍` tapback approves, `👎` denies). |
| Provider keys in `~/.hermes/.env`, chmod 600 | Provider keys in `~/.openclaw/config.yaml`, chmod 600, owned by bridge user. |
| GUI session always active, LaunchAgent under bridge user, auto-login at boot | Unchanged. Tailscale daemon + OpenClaw gateway both run as LaunchAgents in the GUI user session. |
| Bridged-mode LAN exposure caveat | **Eliminated.** macOS Application Firewall default-denies inbound; OpenClaw binds to `tailscale0` or `127.0.0.1` only. Bridged LAN can see the VM exists (ARP, ping) but cannot connect to any service. |
| Clipboard sharing | Unchanged. |
| Read-only shared folder | Removed. Use Tailscale SCP for one-off hand-offs. |

### Net-new surface (OpenClaw-specific)

| Risk | Mitigation |
|---|---|
| ClawHub plugin supply chain (ClawHavoc Jan 2026: 1,400+ malicious skills) | OpenClaw config: `plugins.allowList: [...]` populated with an explicit list. No auto-install from registry. Doctor verifies the allowlist exists and is non-empty. |
| 500K+ exposed OpenClaw instances on the public internet | Default posture prevents this: macOS firewall default-deny + Tailscale-only binding. Doctor's negative connectivity check (Section "Doctor checks") proves the boundary. |
| OpenClaw WebChat auth bypass | `auth.required: true` for WebChat. Token auth even on tailnet (defense in depth). |
| imsg upstream bugs (echo loop #59363, dmHistoryLimit #73172) on any version | Doctor watches for echo-loop pattern (outbound message reflected as inbound within 5s) and warns. No version pin — see Decisions. |
| CVE-class RCE in a future OpenClaw release | Doctor warns if installed version is <3 days post-release (still in the upstream stabilization window). User decides whether to roll forward. |

### Tailscale ACL

- **Inbound** to `tag:vm-claw`: only the user's own tagged devices. Mandatory.
- **Outbound** from `tag:vm-claw`: **unrestricted by design.** An agent that can't reach arbitrary endpoints (LLM provider APIs, the web, package registries, GitHub APIs, whatever a skill needs) is useless. Tailscale ACLs are inbound-only by default; we just don't add outbound rules. The boundary that matters is who can talk *to* the agent, not who the agent can talk to.
- Auth key for `tailscale up` is ephemeral + pre-authorized (single-use). Never committed, never logged, never persisted in plist. Passed via `--auth-key=…` or `--auth-key-file=…`; consumed once.

## Network Posture (summary)

```
  Bridged LAN (default-route interface on host) ─── reachable ARP/ping only
                                                      │
                                                      ▼
                          ┌──────────────────────────────────────────────┐
                          │ VM network interfaces                        │
                          │                                              │
                          │  en0 (bridged)        : firewall default-deny│
                          │  utun0 (tailscale0)   : OpenClaw services    │
                          │  lo0  (127.0.0.1)     : OpenClaw services    │
                          │                                              │
                          │ macOS Application Firewall                   │
                          │   - Block all incoming connections: ON       │
                          │   - Tailscale daemon: explicitly allowed     │
                          │   - All other apps: blocked                  │
                          └──────────────────────────────────────────────┘
```

Tailscale ACL stance:
- `acls`: inbound from user-tagged devices to `tag:vm-claw:*` allowed.
- No outbound restrictions.
- `tagOwners`: VM gets `tag:vm-claw`, owned by the user.

## CLI Surface

### New verbs

| Command | Purpose |
|---|---|
| `vmclaw bootstrap` | Top-level orchestrator: VM create → install-agent → run → tailscale-bootstrap → print "ready, follow runbook to install OpenClaw" |
| `vmclaw bootstrap finalize` | Idempotent post-rebuild check; runs doctor + smoke test |
| `vmclaw vm create [--ipsw=<url>]` | Create VM from Sequoia IPSW (pinned default URL) |
| `vmclaw vm run` | Start the VM |
| `vmclaw vm destroy [--yes]` | Stop + delete the VM |
| `vmclaw vm install-agent` | Install LaunchAgent that auto-starts the VM with `--net-bridged` |
| `vmclaw vm tailscale-bootstrap [--auth-key=… | --auth-key-file=…]` | Inside the VM, install Tailscale + start daemon + `tailscale up` + configure macOS firewall default-deny + verify boundary |
| `vmclaw doctor [--fix]` | Walk the chain top-down; `--fix` for deterministic auto-repair |

### Removed verbs

- `vmclaw hermes bootstrap`
- `vmclaw hermes wire`
- Any other `vmclaw hermes …` subcommands

## Doctor Checks

`vmclaw doctor` walks the chain top-down, prints green/yellow/red rows. `--fix` attempts auto-repair for deterministic items.

**Host checks**
1. `tart` binary installed and on PATH.
2. Host on macOS Tahoe (informational; warn but don't fail if newer).
3. Default-route interface auto-detected; `BRIDGE_HOST_IFACE` override honored.
4. `tailscale` CLI installed on host (so host can reach the VM).
5. Host Tailscale node up and tailnet name resolvable.

**VM lifecycle**
6. `tart list` shows `vm-claw` exists.
7. VM is running (yellow if stopped; `--fix` runs `vmclaw vm run`).
8. VM has a bridged-interface IP; warn if host VPN may have hijacked the default route.
9. LaunchAgent plist exists at expected path and is loaded for the GUI session.

**Inside-VM (over Tailscale SSH or `tart exec`)**
10. VM is macOS Sequoia 15.x (red if Tahoe — wrong IPSW).
11. Bridge Apple ID signed into Messages.app; iMessage Send & Receive enabled.
12. Tailscale daemon running; `tailscale status` shows joined tailnet; node has `tag:vm-claw`.
13. macOS Application Firewall: enabled, block-all-incoming on, Tailscale daemon in allowed-apps list. Reapply with `--fix`.
14. OpenClaw gateway: process running; binding only to `tailscale0` and/or `127.0.0.1`; never `0.0.0.0`.
15. OpenClaw config: `auth.required: true`, `permissions.askConfirmation: true`, `channels.imessage.dmPolicy: allowlist`, `plugins.allowList` populated.
16. OpenClaw version: parse from `openclaw --version`. Doctor cross-checks against the npm registry's promotion timestamp for the `latest` dist-tag; warns yellow if installed = upstream `latest` AND that tag was promoted <3 days ago (still in upstream stabilization window). No hard version pin in our config.

**Negative connectivity (proof of boundary)**
17. From host on the bridged interface, `nc -z <vm-bridged-ip> <openclaw-port>` — must FAIL. Red if it succeeds; the firewall is broken.
18. From host's tailnet IP, `nc -z <vm-tailscale-name> <openclaw-port>` — must SUCCEED.
19. Outbound from VM: `tart exec vm-claw -- curl -sS https://api.anthropic.com/` returns a non-error status. Confirms outbound is intentionally wide open.

**End-to-end smoke** (optional `--smoke`)
20. Send a known wake-word from another iMessage device → confirm OpenClaw audit log shows the message received and a response sent within N seconds.

`--fix` actions (deterministic only):
- Restart stopped VM
- Reload LaunchAgent
- Reapply firewall rules (block-all-incoming + Tailscale allowance)
- Restart Tailscale daemon if down

Everything else (Apple ID signed out, OpenClaw config drift, Tailscale auth expired) stays yellow with a documented recovery step.

## Cleanup + Rebuild Sequencing

Three phases. Each phase has a clear done signal before the next begins.

### Phase A — Repo rescope (reversible)

1. Work on feature branch `rescope-openclaw-sequoia`. Open PR when done. Merge to main only after end-to-end smoke passes in Phase C.
2. Write this spec; add supersedes header to old spec.
3. Delete `internal/hermes/`, `internal/cli/hermes.go`, Hermes refs in `internal/cli/bootstrap.go` and `internal/cli/root.go`.
4. Retarget `internal/vm/tart.go` IPSW default to Sequoia 15.x.
5. Add `internal/tailscale/setup.go`, `internal/vm/firewall.go`, `internal/cli/tailscale.go`.
6. Replace doctor checks in `internal/doctor/checks.go`.
7. Rewrite CLAUDE.md and README.md.
8. `make` clean; existing tests pass; new tests for tailscale and firewall packages.
9. Push branch; open PR.

**Done signal:** PR opens cleanly; `make test` green.

### Phase B — Destructive cleanup on the host (irreversible)

10. Back up `~/.hermes/.env` → `~/Documents/vmclaw-backup.env`, `chmod 600`.
11. `tart stop bridge-vm` if running; `tart delete bridge-vm`.
12. `tart delete ghcr.io/cirruslabs/macos-tahoe-base:latest`.
13. `tart delete ghcr.io/cirruslabs/macos-tahoe-base@sha256:f883f13f3f076ee2aa97f92a7341801f83655037dcfecd184872574d5664cbde`.
14. `launchctl bootout` the old `bridge-vm` LaunchAgent; remove the plist.
15. `colima stop` → `colima delete` → `rm -rf ~/.colima`.
16. `brew uninstall colima docker` (if installed via brew).
17. `rm -rf ~/.docker`.
18. `rm -rf ~/.hermes`.
19. Verify reclaim: `du -sh ~/.tart ~/.colima ~/.hermes ~/.docker` → all missing or empty. `tart list` empty.

**Done signal:** ~64 GB+ reclaimed; no Tart VMs; no Colima; no Hermes data.

### Phase C — Rebuild on Sequoia

20. `vmclaw vm create --ipsw <pinned-sequoia-url>` (creates fresh `vm-claw`).
21. `vmclaw vm install-agent` (LaunchAgent with `--net-bridged=<host-iface>`).
22. `vmclaw vm run` (or wait for LaunchAgent to start it).
23. **Manual GUI step:** sign into the reused bridge Apple ID; enable iMessage; complete activation.
24. `vmclaw vm tailscale-bootstrap --auth-key=tskey-…` (Tailscale install + `tailscale up` + firewall lockdown + boundary verification).
25. **Manual SSH step over tailnet:** install OpenClaw (latest stable, no pin) inside the VM; copy provider keys from `~/Documents/vmclaw-backup.env` into `~/.openclaw/config.yaml`; populate the plugin allowlist; load OpenClaw gateway LaunchAgent.
26. `vmclaw doctor` — green across the chain.
27. End-to-end smoke: send an iMessage from another device → OpenClaw responds.
28. Once green: PR from `rescope-openclaw-sequoia` → `main`, merge.

**Done signal:** doctor green; round-trip iMessage works; PR merged.

## Decisions

| Decision | Value | Rationale |
|---|---|---|
| Host OS | macOS Tahoe (unchanged) | Can't downgrade host. Vmnet stopgap (`--net-bridged`) persists. |
| Guest OS | macOS Sequoia 15.x (latest available IPSW) | Sequoia is unaffected by the Tahoe iMessage regressions; Tart fully supports Sequoia guest on Tahoe host. |
| Agent runtime | OpenClaw, native in the VM | Replaces Hermes-in-Docker. Removes Colima from host. |
| iMessage path | `imsg` over JSON-RPC | OpenClaw's first-class iMessage adapter; BlueBubbles removed by OpenClaw upstream. |
| Apple ID | Reuse existing bridge Apple ID | Continuity of iMessage threads; lower activation risk than a fresh ID. |
| Network access | Tailscale-only inbound | Smallest practical inbound surface; no LAN exposure. |
| Outbound network | Unrestricted | An agent with restricted outbound is hobbled — see [[feedback_agent_outbound_unrestricted]]. |
| OpenClaw version | Latest stable (`@latest`), no pin | User's explicit choice. Trade: auto-upgrades reduce manual version chase; doctor warns on releases <3 days old to give a stabilization window. |
| VM name | `vm-claw` (renamed from `bridge-vm`) | Matches repo name; "bridge" was stale terminology in the new scope. |
| CLI surface | Slim (VM + Tailscale + doctor); OpenClaw setup is a manual runbook | User's explicit choice. Less code, more documentation. |
| Branch strategy | Feature branch `rescope-openclaw-sequoia` + PR | Sweeping change; coherent diff for review; reversible up to merge. |
| `~/.hermes/` | Nuked after `.env` backup | User explicit; provider keys preserved, session/skill state lost. |

## Risks (accepted, with mitigations)

1. **imsg echo loop / dmHistoryLimit upstream bugs** ([openclaw/openclaw#59363](https://github.com/openclaw/openclaw/issues/59363), [#60429](https://github.com/openclaw/openclaw/issues/60429), [#73172](https://github.com/openclaw/openclaw/issues/73172)) — not Tahoe-specific; Sequoia inherits them. Doctor watches for echo-loop pattern.
2. **ClawHub plugin supply chain** — recurring vector; ClawHavoc was real. Explicit plugin allowlist + no auto-install.
3. **Apple ID activation grey area in a VM** — established account lowers risk vs fresh. Documented recovery: sign out in Messages, wait 30s, sign back in. Hard rail: never use host user's Apple ID.
4. **macOS firewall has known bypasses** — defense in depth only. Tailscale binding is the primary boundary; doctor's negative connectivity check (#17) is the proof.
5. **Tracking latest stable means a 4.29-class release will reach the VM eventually** — accepted because user prefers auto-upgrade over manual version chase. Doctor's <3-day stabilization warning is the mitigation; user can downgrade if doctor flags red.

## Open Implementation Questions

These won't block this spec; they're resolved during plan-writing and Phase A.

1. **OpenClaw install command** — OpenClaw is npm-distributed (`npm install -g openclaw` or `npx openclaw`?). Need to verify exact form before writing the README runbook.
2. **`imsg` install path** — separate repo `openclaw/imsg`. Need to confirm: brew tap, npm bundle, prebuilt binary, or sub-command of openclaw CLI?
3. **Tailscale on Sequoia** — App Store version requires GUI confirmation for network extension; the standalone CLI/cask version is headless-installable. Confirm `brew install --cask tailscale` provides a usable headless daemon, or fall back to the official PKG installer.
4. **Sequoia IPSW pin target** — pick the latest 15.x point release Apple still serves; record URL + sha256. Re-pin annually.
5. **Tailscale auth-key handling UX** — `--auth-key=…` (env-equivalent) vs `--auth-key-file=…` (path). Pick during plan-writing.
6. **OpenClaw config sample** — concrete YAML for `~/.openclaw/config.yaml` including all security-contract keys. Goes into the repo as `docs/openclaw-config.example.yaml`.

## Recovery Paths

When something silently breaks, work down this list before deeper debugging:

1. **`vmclaw doctor`** — green/red across the chain.
2. **VM not booting / no IP** — `tart list` and `tart ip vm-claw`. If VM exists but has no IP, run `vmclaw vm run` in another terminal, or `vmclaw vm install-agent` to load the LaunchAgent. Bridged DHCP comes from the LAN router — unhealthy LAN means unhealthy VM.
3. **Wrong bridge interface picked up** — auto-detect uses the IPv4 default route; a VPN can hijack it. Override with `BRIDGE_HOST_IFACE=en0 vmclaw vm run` and re-run `vmclaw vm install-agent`.
4. **Host can't reach VM over Tailscale** — `tailscale status` on host; verify `vm-claw` shows up. Inside VM: `tailscale status` and `tailscale up --reset` if the auth expired.
5. **iMessage stops sending** — log into the VM GUI, open Messages.app, confirm iMessage is still active. macOS sleep on the VM is the most common cause; verify "Display sleep when on power adapter" is still off.
6. **OpenClaw responding from wrong handle / not responding** — check `~/.openclaw/config.yaml` for `channels.imessage` allowlist drift; check the gateway LaunchAgent is loaded.
7. **Apple ID activation loop** — sign out of the Apple ID in Messages (not System Settings), wait 30 s, sign back in. If persistent, recreate the Apple ID; running iMessage in a VM is a grey area with Apple.
8. **VM is unrecoverable / suspect / over-updated** — `vmclaw vm destroy --yes && vmclaw bootstrap`, then re-run the manual runbook. The bridge Apple ID is portable; only local Messages history and the OpenClaw skill/memory state are lost.
9. **Doctor red on negative connectivity (#17)** — firewall is broken. Re-run `vmclaw vm tailscale-bootstrap` to reapply, then doctor again. If still red, SSH in over tailnet and run `socketfilterfw --setblockall on` by hand.

## Migration Path (for archaeology)

For someone reading the prior spec ([`2026-05-04-hermes-imessage-bridge-vm-design.md`](./2026-05-04-hermes-imessage-bridge-vm-design.md)) and wondering what changed:

| Prior model | New model |
|---|---|
| Hermes container on host, talking to BlueBubbles in a Tahoe bridge VM | OpenClaw native in a Sequoia VM, talking to Messages.app directly via `imsg` |
| Two-layer transport: Hermes → BlueBubbles REST → Messages.app | One-layer transport: OpenClaw → `imsg` JSON-RPC → Messages.app |
| Hermes hardening keys (`terminal.docker_forward_env`, etc.) | OpenClaw equivalents (`terminal.persistent`, `permissions.askConfirmation`, `plugins.allowList`) |
| Network: bridged LAN exposes BlueBubbles port | Network: Tailscale-only inbound, firewall default-deny, no LAN exposure |
| VM name `bridge-vm`; single-purpose iMessage relay | VM name `vm-claw`; runs the entire agent stack |
| Colima + Docker on host | No Colima, no Docker on host |
| Multi-profile Hermes support (default + named profiles, distinct ports) | Single OpenClaw instance per VM. Multi-profile, if ever needed, becomes "multiple VMs." |
