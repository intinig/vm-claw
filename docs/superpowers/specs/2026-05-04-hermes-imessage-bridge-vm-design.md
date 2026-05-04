# Hermes + iMessage bridge VM — design spec

**Date:** 2026-05-04
**Status:** Approved (per brainstorming session); pending implementation.
**Replaces:** the prior `SPEC.md` at the repo root and the OpenClaw scope it inherited from.

## Goal

Run [Hermes Agent](https://hermes-agent.nousresearch.com/) on the macOS host in Docker (via Colima), and give it the ability to send and receive iMessage under an Apple ID **distinct** from the host user's.

Hermes itself stays on the host. A single-purpose Tart VM hosts the second Apple identity, runs Messages.app, and exposes [BlueBubbles Server](https://bluebubbles.app/server/) as the bridge protocol. Hermes' first-party BlueBubbles connector handles both directions; no custom Hermes skill is required.

### Non-goals

- Isolating Hermes itself. Hermes already runs in a container; tightening that lives in `~/.hermes/config.yaml`, not here.
- Sandboxing untrusted agents inside macOS. The OpenClaw scope is retired.
- Supporting multiple bridge Apple IDs simultaneously. One VM = one Apple ID. A future spec can add multi-identity if it becomes a real need.

## Why a VM (rather than a second host user)

iMessage is bound to the Apple ID of the logged-in macOS *user account*.

1. **Second user on the host.** Cheap, but Messages.app on a fast-user-switched background user is fragile (idle/sleep, push delivery drops out), and a second Apple ID on the same login session mixes identities with the host user's keychain. Rejected.
2. **Separate VM.** Full macOS install with its own login, keychain, Apple ID, trusted-device set, Messages history. Always running, isolated from the host user's identity, easy to wipe. **Chosen.**
3. **Dedicated physical Mac.** Cleanest but cost/space overhead. Out of scope unless the VM path proves unworkable.

## Architecture

```
+------------------------------ macOS host -------------------------------+
| user: <you>                                                             |
|                                                                         |
|  Colima VM (Linux) ── Docker ──┐                                        |
|     hermes-agent container     │ docker --add-host bridge-vm:<ip>       |
|     hermes-dashboard container │ outbound HTTP to http://bridge-vm:1234 |
|                                │                                        |
|                                ▼                                        |
|                  Colima vmnet ─▶ host kernel forwards                   |
|                                  vmnet ↔ softnet bridge                 |
|                                ▼                                        |
|  +----------------- Tart VM (macOS guest, softnet) ----------------+    |
|  | user: bridge (auto-login)                                       |    |
|  | Apple ID: <distinct, fresh>                                     |    |
|  | Messages.app signed in, iMessage active                         |    |
|  | BlueBubbles Server (Login Item)                                 |    |
|  |   - REST: send messages (port 1234)                             |    |
|  |   - Socket.IO + webhook: incoming → POSTs to Hermes gateway     |    |
|  |     at http://<softnet-gw-ip>:8642/<connector-path>             |    |
|  |   - Bind: 0.0.0.0:1234 (only reachable via softnet)             |    |
|  |   - Password in ~/.hermes/.env                                  |    |
|  |   - FCM / Proxy URL: disabled                                   |    |
|  +-----------------------------------------------------------------+    |
+-------------------------------------------------------------------------+
```

The VM is a single-purpose appliance: a logged-in macOS desktop session with Messages.app running and BlueBubbles exposing an API. Hermes calls it to send messages and consumes its webhook to receive them.

## Components

### Host side

1. **Colima VM + Docker daemon.** Existing `hermes-setup.sh` covers this; no change. Defaults (4 CPU / 8 GB / 80 GB / aarch64 / runtime=docker) are fine.
2. **Hermes gateway container.** Runs `nousresearch/hermes-agent gateway run`, publishes `0.0.0.0:8642`. New: `~/.hermes/.env` carries the BlueBubbles credentials (server URL + password + webhook secret) for Hermes' first-party BlueBubbles connector. Exact key names verified against Hermes docs at implementation time.
3. **Hermes container `--add-host` wiring.** No host-side port forwarder. The `docker run` invocations in `hermes-setup.sh`'s next-step output (and any wrapper used to relaunch the container) include `--add-host bridge-vm:$(tart ip bridge-vm)` so the hostname `bridge-vm` resolves inside the container. Container traffic to `http://bridge-vm:1234` exits Colima's vmnet, the host kernel forwards it across to the softnet bridge, and BlueBubbles answers. The IP is captured at container start; if the VM's softnet IP changes (rare), restart the container to refresh.

### Bridge VM side

4. **Tart VM.** Tahoe base image (`ghcr.io/cirruslabs/macos-tahoe-base:latest`, no SHA pin), softnet networking, base-image default disk (no expansion), no shared folder.
5. **Bridge user + GUI session.** Single dedicated macOS user (`bridge`). Auto-login at boot. Sleep disabled. iCloud Drive/Photos/etc. disabled — only iMessage activated.
6. **BlueBubbles Server.app.** Downloaded from `bluebubbles.app` inside the VM. Login Item under the bridge user so it starts when the user auto-logs-in. Configured for LAN-only operation:
   - Bind: `0.0.0.0:1234`.
   - Password: set at first run, copied into `~/.hermes/.env`.
   - FCM / Firebase: disabled.
   - Proxy URL (Cloudflare/ngrok): blank.
   - Webhook: POSTs incoming-message events to `http://<softnet-gw-ip>:8642/<connector-path>` using a shared secret.

### What we are explicitly NOT building

- No custom Hermes iMessage skill (BlueBubbles is first-party).
- No custom service in the VM beyond BlueBubbles itself.
- No host-side event router — BlueBubbles webhooks straight to Hermes' gateway.
- No shared folder between host and VM.

### Interface boundaries

| From | To | Protocol | Auth |
|---|---|---|---|
| Hermes container | BlueBubbles | HTTP REST `http://bridge-vm:1234` (resolves via `--add-host`) | BlueBubbles password in `.env` |
| BlueBubbles | Hermes gateway | HTTP webhook `<softnet-gw>:8642/...` | shared secret (URL or header — pin at impl time) |
| Host operator | Bridge VM | SSH | Tart-managed key |

## Network model

### Topology

- VM uses softnet → its own NAT, no leakage of the host's VPN/routes into the guest. Outbound to Apple's iMessage servers works through that NAT.
- Host reaches VM directly via the softnet-assigned IP (resolved by `tart ip bridge-vm`).
- Hermes container reaches VM via `http://bridge-vm:1234`. The hostname is injected via `docker run --add-host bridge-vm:<ip>` at container start. Container traffic exits Colima's vmnet, the host kernel forwards across to the softnet bridge, and BlueBubbles answers. No host-side port forwarder.
- VM reaches Hermes gateway via the softnet *gateway* IP (the host's bridge-side interface), since the gateway container's `-p 8642:8642` makes the endpoint reachable on every host interface.

This relies on three things that are true by default on macOS but worth knowing:

1. macOS enables `net.inet.ip.forwarding=1` automatically when vmnet starts. Without it, the host wouldn't route packets between vmnet (Colima's) and softnet (Tart's) bridges.
2. The Colima Linux VM's default route points at the host (vmnet gateway), so any non-vmnet-subnet traffic transits through the host.
3. The host's routing table includes the softnet bridge subnet automatically when softnet is up.

### Foot-gun

If user-installed `pf` rules (LittleSnitch, certain VPN clients, corporate MDM) block forwarding between vmnet and the softnet bridge, the container ↔ VM path breaks. Diagnostic from the host:

```bash
# 1. Bridge VM reachable from the host directly?
curl "http://$(tart ip bridge-vm):1234/api/v1/server/info?password=<pw>"
# 2. Bridge VM reachable from inside a Colima container?
docker run --rm --add-host bridge-vm:$(tart ip bridge-vm) alpine \
  wget -qO- "http://bridge-vm:1234/api/v1/server/info?password=<pw>"
```

Step 1 passing + step 2 failing = host is dropping the cross-bridge forward. Inspect `pfctl -s rules` and any active VPN.

### Ports

| Port | Bound on | Purpose |
|---|---|---|
| `1234` | VM `0.0.0.0` (only reachable via softnet) | BlueBubbles HTTP/Socket.IO |
| `8642` | Host `0.0.0.0` | Hermes gateway; reached by Colima containers via Docker, and by the bridge VM via the softnet gateway IP |
| `9119` | Host `0.0.0.0` | Hermes dashboard |

### Existing softnet collision check

`setup.sh` and `run.sh` carry a `check_vmnet_subnet_collision` that diagnoses the Tahoe vmnet subnet bug (vmnet picks a subnet from `/var/db/dhcpd_leases` that may collide with the host LAN). Unrelated to this redesign; keep as-is.

## Security model

### What we protect

- The host user's Apple ID and iMessage history. Stays on the host, never visible to Hermes or the VM.
- The bridge Apple ID and its keychain. Stays inside the VM. Host FileVault covers the VM disk file at rest.

### What we do NOT protect

- Hermes from itself. Hermes is trusted relative to this project. Container-level hardening lives in `~/.hermes/config.yaml`.
- The VM from a compromised Hermes. A compromised Hermes can send arbitrary iMessages from the bridge identity. **Mitigation:** `approvals.mode: manual` is now load-bearing — it ensures every outbound send prompts the user.

### Hermes hardening contract (unchanged)

Apply these in `~/.hermes/config.yaml` after the upstream `setup` wizard runs:

- `terminal.docker_forward_env: []`
- `terminal.container_persistent: false`
- `terminal.docker_mount_cwd_to_workspace: false`
- `approvals.mode: manual` ← required for iMessage send safety

`.env` permissions: `chmod 600 ~/.hermes/.env`.

### Apple-ID risk

Running iMessage in a VM is a grey area with Apple. Apple may flag the device as suspicious and force re-verification, or in rare cases lock the Apple ID. Use a fresh Apple ID created for this purpose, not a personal one.

## VM provisioning runbook

Manual, one-time. Apple Setup Assistant + 2FA + GUI permissions cannot be safely automated.

### Prerequisites

- Fresh Apple ID. Create on another trusted device beforehand or inline during macOS Setup Assistant.
- Trusted device for 2FA. Phone or another Mac signed into the bridge Apple ID.
- Optional: phone number for the Apple ID's reachability. Not all VOIP numbers are accepted by Apple for new IDs.

### Order of operations (after `./setup.sh && ./run.sh`)

```
A. macOS Setup Assistant
   1. Region / keyboard / network — anything works.
   2. Migration: skip.
   3. Apple ID: sign in OR skip-then-add-later in System Settings.
      ↳ 2FA prompt; approve from trusted device.
   4. Create the macOS user named "bridge".
   5. Skip Touch ID, Apple Pay, Siri, Screen Time, FileVault prompt.

B. macOS hardening (System Settings)
   1. Users & Groups → Login Options → Auto-login: bridge user.
   2. Lock Screen → "Display sleep when on power adapter": never.
      ↳ Without this, BlueBubbles' connection to Apple's servers idles out.
   3. Energy Saver → "Wake for network access": off.
   4. Apple ID → iCloud: disable everything (Drive, Photos, Contacts, Messages
      in iCloud, etc.). iMessage activation lives in Messages.app, separate
      from iCloud — leave it for step C.

C. Messages.app
   1. Open Messages, sign in (reuses the Apple ID).
   2. Settings → iMessage → enable.
   3. "You can be reached at": confirm Apple ID email shows + is checked.
   4. Send a test message to a known recipient from another device.
      ↳ Verify it lands here. If not, do not proceed.

D. BlueBubbles Server.app
   1. In the VM's browser, download from https://bluebubbles.app/install/.
   2. Open the .dmg, drag to /Applications, launch.
   3. macOS prompts: grant Full Disk Access (System Settings → Privacy &
      Security → Full Disk Access → BlueBubbles Server). Required to read
      Messages' chat.db.
   4. macOS prompts: grant Automation → Messages.
   5. macOS prompts: grant Accessibility.
   6. First-run wizard: set admin password. Save it.
   7. Settings → Server: bind 0.0.0.0:1234. Disable FCM. Leave Proxy URL blank.
   8. Settings → API & Webhooks: add webhook URL pointing at
      http://<softnet_gw_ip>:8642/<connector-path> with a shared secret.
   9. System Settings → General → Login Items → add BlueBubbles Server.

E. Host-side wiring
   1. Copy BlueBubbles password into ~/.hermes/.env per the connector docs.
   2. Validate the host-to-VM path directly:
        curl "http://$(tart ip bridge-vm):1234/api/v1/server/info?password=<pw>"
      Should return BlueBubbles' server-info JSON.
   3. Validate the container-to-VM path:
        docker run --rm \
          --add-host bridge-vm:$(tart ip bridge-vm) \
          alpine wget -qO- \
          "http://bridge-vm:1234/api/v1/server/info?password=<pw>"
      Same JSON — confirms vmnet ↔ softnet forwarding works.
   4. Restart the Hermes gateway/dashboard containers with --add-host
      bridge-vm:$(tart ip bridge-vm) baked in.
   5. Send a message *to* the bridge identity from another device.
      Watch Hermes logs for the inbound webhook POST.
```

### Recovery / known issues

- **iMessage not activating.** Apple sometimes flags VMs. Symptom: Messages.app shows "Activating…" indefinitely. Workaround: sign out of the Apple ID in Messages, sign back in. If persistent, recreate the Apple ID or use a different one.
- **2FA loop.** If your trusted device disappears, Apple ID account recovery is the only path back in. Keep one trusted device alive at all times.
- **macOS update during operation.** Major updates require GUI interaction in the VM and disk headroom. With base-image default disk size, one major update should fit; consecutive ones may not. Plan to wipe-and-reprovision rather than chase updates.
- **Cross-major macOS bumps.** `cirruslabs/macos-tahoe-base:latest` only floats *within* Tahoe. When macOS bumps to the next major, the image *name* needs a manual update in `setup.sh` — there is no cross-version rolling tag.

## Migration plan

Ordered smallest-first. Detailed step-by-step lives in the implementation plan written by `writing-plans` after this spec is approved.

### Phase 1 — Repo housekeeping

1. **Tag preserve point.** `git tag openclaw-final && git push --tags`. Recovery anchor for the old layout.
2. **Update SPEC, README, CLAUDE.md** to reflect this design.
3. **Repoint Tart scripts** (smallest possible diff):
   - `setup.sh`: `VM_NAME=bridge-vm`, `BASE_IMAGE=ghcr.io/cirruslabs/macos-tahoe-base:latest` (no SHA pin), drop `DISK_SIZE_GB` + `tart set --disk-size`, drop `SHARED_DIR` + `mkdir`, update banner.
   - `run.sh`: `VM_NAME=bridge-vm`, drop `SHARED_DIR` block + `--dir=shared:...` flag, update banner.
   - `destroy.sh`: `VM_NAME=bridge-vm`, update banner.
   - Keep `check_vmnet_subnet_collision` and the destroy-confirmation prompt unchanged.

### Phase 2 — Bridge VM provisioning (manual, one-time)

4. **Create the VM.** `./setup.sh && ./run.sh`.
5. **Run the runbook above.** End state: BlueBubbles serving on `<vm-ip>:1234`, password noted, webhook configured.
6. **Sanity check from host.** `tart ip bridge-vm` resolves; `curl http://<vm-ip>:1234/api/v1/server/info?password=<pw>` returns JSON.

### Phase 3 — Hermes container wiring

7. **`--add-host` plumbing.** Update `hermes-setup.sh` (and any helper script that re-launches the gateway/dashboard) so the printed `docker run` invocations include `--add-host bridge-vm:$(tart ip bridge-vm)`. The container resolves the VM by name without a host-side forwarder. Smoke test from inside the container: `wget -qO- http://bridge-vm:1234/api/v1/server/info?password=<pw>` returns BlueBubbles' server-info JSON.

### Phase 4 — Hermes integration

8. **Wire BlueBubbles connector.**
   - Verify exact Hermes config keys / env vars against current Hermes docs.
   - Update `~/.hermes/.env` with server URL + password + webhook secret.
   - Restart Hermes gateway container.
   - End-to-end: send via Hermes API → receive on a real device. Reply from real device → see it land in Hermes session.

### Phase 5 — Polish (defer until 1–4 work)

9. **Auto-start the bridge VM on host boot.** A separate LaunchAgent that runs `tart run --net-softnet bridge-vm`.
10. **Host-side healthcheck script.** VM up? BlueBubbles reachable? Hermes config consistent?
11. **Document recovery paths in CLAUDE.md.** Apple ID lock, iMessage activation failure, VM rebuild from scratch.

## Decisions log

Captured during the brainstorming session that produced this spec.

| Decision | Choice | Reasoning |
|---|---|---|
| iMessage usage shape | Symmetric (send + receive, live conversation) | User intent. |
| Bridge transport | BlueBubbles Server in VM | Hermes has first-party BlueBubbles support; no custom skill needed. |
| BlueBubbles deployment | LAN-only minimal (no FCM, no Proxy URL) | Smallest attack surface; isolation goal. |
| Container ↔ VM plumbing | `docker run --add-host bridge-vm:<ip>` (no host-side forwarder) | Initial draft used a socat LaunchAgent on `127.0.0.1`; that doesn't work because Colima containers reach the host via `host.docker.internal`, which resolves to the host's vmnet-side IP, not loopback. `--add-host` lets the container address the VM directly and the host kernel forwards vmnet ↔ softnet. |
| VM name | `bridge-vm` | Neutral, function-describing. |
| Shared folder | Drop entirely | BlueBubbles install + password handoff don't require it. |
| VM disk size | Base-image default (no `tart set --disk-size`) | Tart only grows disks, never shrinks; start small. |
| Base image pin | `:latest` (no SHA pin) | Follow freshest cirruslabs Tahoe build. |
| OpenClaw script history | `git tag openclaw-final` then overwrite | Cheap insurance, no branch maintenance. |
| Multiple bridge identities | Out of scope (one VM = one Apple ID) | Defer to a future spec if needed. |

## Open implementation details (deferred)

- **Webhook auth scheme** — URL secret vs. `Authorization` header. Pin at implementation time per Hermes' BlueBubbles connector docs.
- **Hermes BlueBubbles connector env var names** — verify against Hermes docs at implementation time rather than commit names from memory.

---

**Update 2026-05-04: superseded by `vmclaw` CLI.** The Phase 1.3 script
edits, Phase 3 `--add-host` plumbing, Phase 4 wiring, and Phase 5 polish
in this spec's migration plan are subsumed by the
[`vmclaw` CLI design spec](./2026-05-04-vmclaw-cli-design.md). The
runbook section above (`#vm-provisioning-runbook`) is still
authoritative for the manual Phase 2 work; everything automatable now
lives behind `vmclaw <subcommand>`.


---

**Update 2026-05-04 (Hermes connector reality check).** The "shared
webhook secret" assumption in the Webhook auth scheme decision is
wrong. Hermes' BlueBubbles connector authenticates by sender identity
(DM-pairing flow or `BLUEBUBBLES_ALLOWED_USERS` allowlist). The
webhook listener runs in the Hermes container on port `8645` at path
`/bluebubbles-webhook`, separate from the gateway. See the
[vmclaw spec's update note](./2026-05-04-vmclaw-cli-design.md) and
[Hermes' BlueBubbles docs](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/bluebubbles).
The provisioning runbook in this doc still asks the user to configure
a webhook URL — but the URL target and auth scheme should follow the
Hermes docs, not this spec's original "Bearer header" wording.
