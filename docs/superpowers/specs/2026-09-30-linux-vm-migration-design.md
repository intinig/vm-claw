# vm-claw on Linux — Design

Move OpenClaw off the Tart macOS VM onto a reproducible Lima + Debian VM on the
same host, without losing any state.

## Goal

A Linux VM that runs the whole OpenClaw stack exactly as it runs today (minus
iMessage), can be rebuilt from this repo plus the latest backup, and turns OS
upgrades into routine work instead of a gamble.

## Why

The current guest is a Tart macOS VM. Every macOS-guest tool on Apple silicon
(Tart, Lume, UTM, VirtualBuddy, Parallels) sits on Apple's
Virtualization.framework and shares its limits, so switching tool fixes nothing:

- In-guest macOS updates are unreliable: an OTA update can reboot and silently
  revert ([tart#1232](https://github.com/cirruslabs/tart/issues/1232)), and
  `softwareupdate` inside a guest can leave it seeing ~1.8 GB of usable memory
  regardless of allocation
  ([macos-image-templates#385](https://github.com/cirruslabs/macos-image-templates/issues/385)).
  The OpenClaw gateway alone uses ~2 GB.
- No App Store sign-in in guests, and a two-running-macOS-VMs licence cap.
- OpenClaw's own docs recommend a macOS VM only for iMessage or isolation
  ([docs.openclaw.ai/install/macos-vm](https://docs.openclaw.ai/install/macos-vm)).

iMessage was the only thing tying the guest to macOS, and it is being dropped.

## Requirements

Stated by the owner:

1. **Isolation.** The agent has exec tools; it must not run on the host.
2. **SSH into the claw machine** — a VM, not a container.
3. **Lose nothing.** Every piece of state is carried over or deliberately left.
4. **Reproducible.** Rebuild = this repo + the latest backup.
5. **Drop iMessage.** It was a WhatsApp-down backup; Tailscale now covers
   remote troubleshooting.

Carried over from this repo's original security requirements: isolated NAT
networking, no clipboard sharing, no writable host mounts.

## Non-goals

- Changing OpenClaw's configuration, models, agents or cron jobs beyond what the
  platform change forces (paths, service manager, dropping iMessage).
- Upgrading tool versions during the move. Versions are pinned to what runs
  today; upgrades happen afterwards, one at a time, each behind a backup.

## Current state (inventory, 2026-09-30)

- Guest: macOS 15.7.3, 49 GB disk, Tart 2.32.1, started by a host launchd agent
  running `tart run --net-bridged=en1 vm-claw`. Bridged, i.e. on the home LAN —
  contrary to this repo's stated NAT requirement. Nothing inside the guest was
  scripted; `setup.sh`/`run.sh` only clone a base image.
- OpenClaw 2026.9.7 on node 24, launchd user agent `ai.openclaw.gateway`.
  Plugins: openai, codex, imessage, brave, whatsapp, deepseek, google,
  memory-wiki, memory-core, browser. Channels: WhatsApp, iMessage. Two agents
  (`main`, `vera`). 20 automations. Every macOS-only skill (Apple Notes,
  Reminders, Things, Bear, Peekaboo) is disabled; only `sag` is enabled.
- Secrets: all config secrets are 1Password SecretRefs resolved by `op read`
  exec providers, bootstrapped by one `OP_SERVICE_ACCOUNT_TOKEN` in the gateway
  env file (mode 600). `openclaw secrets audit --allow-exec` is clean
  (plaintext=0, unresolved=0) after the legacy OpenAI profile was removed.
- State that exists only inside the VM:

  | Path | Size | Notes |
  |---|---|---|
  | `~/.openclaw` | 5.5 GB | config, state DBs, agents, sessions, workspaces, WhatsApp creds; covered by `openclaw backup` |
  | `~/brain` | 97 MB | OCSB harvester, prompts, queue, cursors — not a git repo |
  | `~/brain/vault` | — | git, pushed to its GitHub remote (the one thing already off-box) |
  | `~/.wacli` | 21 MB | second WhatsApp linked device: 13k-message store + session |
  | `~/.ssh` | — | vault deploy key, `config`, `authorized_keys` |
  | `~/ops` | <1 MB | listener guard, benchmark scripts |
  | `~/backups` | 5.2 GB | `openclaw backup` tarballs — inside the VM, so not a backup of the VM |

- Leftovers not carried: GitHub Actions and GitLab runners and `.ansible` (from
  the Cirrus Labs base image; unconfigured), Codex.app, the 1Password desktop
  app, Memo, `imsg`, retired/stale OpenClaw dirs (archived with the migration
  backup, not restored).

## Design

### 1. Architecture

**Host.** Lima from Homebrew core (no third-party tap). One instance, `claw`,
defined in `lima/claw.yaml`: Debian 13 (trixie) arm64 on the `vz` backend —
native virtualization, no emulation. 4 vCPU, 8 GiB RAM (confirm against host
RAM; keep at least 8 GiB for the host), 100 GiB sparse disk. Autostart with
`limactl start-at-login claw`.

**Isolation, enforced in `claw.yaml` and the guest:**

- `mounts: []` — Lima mounts the host home directory by default; this must be
  explicit.
- `portForwards`: exactly one rule, guest `127.0.0.1:18789` → host
  `127.0.0.1:18789`, followed by a catch-all ignore rule. Lima forwards every
  listening guest port by default.
- NAT networking only; the VM gets no LAN address.
- Guest egress firewall (`nftables`): drop outbound to RFC1918 and link-local
  ranges; allow loopback, established traffic, DNS to Lima's NAT gateway, the
  internet, and Tailscale's `100.64.0.0/10`.
- No GUI, so no clipboard.

**Access.** Tailscale inside the guest, hostname `vm-claw`, so
`ssh admin@vm-claw` and `scp`/`rsync` keep working from anywhere on the tailnet.
Fallback from the host when Tailscale is down: `limactl shell claw` or `ssh`
through Lima's localhost endpoint. `sshd` is key-only.

**Face integration.** The appliance app keeps connecting to
`ws://127.0.0.1:18789`. Lima's port forward replaces the host's gateway SSH
tunnel launchd agent, which is removed at cutover.

**Repo layout:**

```
lima/claw.yaml             VM definition
provision/provision.sh     idempotent guest provisioning (run as root)
provision/versions.env     pinned versions + release checksums
migrate/export.sh          runs on the old VM: stop, back up, package file-state
migrate/import.sh          runs on the new VM: restore, rewrite paths, verify
migrate/rewrite-paths.*    path rewrite, separately testable
ops/listener-guard/        guard + systemd user units (moved from ~/ops)
ops/backup/                nightly backup units + host pull job
host/                      start-at-login, tunnel-agent removal, host pull agent
README.md                  runbook: rebuild, cutover, rollback, upgrade, restore
```

The Tart scripts stay until the rollback window closes, then are deleted along
with the Tart-specific `CLAUDE.md` content. The repo is public: no secrets, IPs,
phone numbers or account identifiers are ever committed.

### 2. Provisioning

`provision.sh` is copied into the guest with `limactl copy` and run through
`limactl shell` as root. Every step checks state before acting, so re-running it
is safe; it is both the build and the upgrade path. Versions come from
`versions.env`; release downloads are checksum-verified.

**Installed — each has a consumer today:**

- node 24 (NodeSource), matching the gateway's current major.
- OpenClaw `2026.9.7` via npm. Plugin install projects are regenerated by
  `openclaw update repair` / `openclaw doctor --fix`, not copied.
- `op` (1Password apt repo).
- Tailscale (official apt repo); `tailscale up --hostname=vm-claw`, interactive
  login once.
- `wacli 0.13.0` and `sag 0.3.0` from their linux-arm64 GitHub release
  tarballs, matching the running versions (see Verification before build).
- Chromium (Debian package) for the browser plugin.
- `git`, `jq`, `sqlite3`, `curl`, `gh`, `poppler-utils`, `zip`/`unzip`;
  `summarize` via npm.

**Not installed — nothing uses them:** whisper.cpp (its model is already
missing, so media STT does not work today), awscli, mise, rbenv, cmake/gcc,
git-lfs, yq, `imsg`, `memo`, CI runners, GUI apps. Each is one line to add.

**System:** user `admin` with its home as a real directory at **`/Users/admin`**
(see §3, "Paths"), timezone copied from the old guest (UTC; cron schedules carry
their own time zones), compatibility symlinks in `/opt/homebrew/bin/` for the
binaries named in free text, `unattended-upgrades` for the security pocket only,
`nftables` rules from §1.

**Services (systemd, user scope, `loginctl enable-linger admin`):**

- Gateway: unit created by `openclaw gateway install`, so OpenClaw's own
  `doctor`/`update` keep managing it. Bootstrap token written to
  `~/.openclaw/service-env/*.env`, mode 600 — read from the host with `op read`
  during provisioning, or prompted once. It never touches the repo.
- Listener guard: systemd timer every 2 minutes; restart via
  `systemctl --user restart <gateway unit>` instead of `launchctl kickstart`.
  Same detection rules, thresholds and replay mode as today.
- Nightly backup timer (§4).

### 3. Migration and cutover

**Step 0 — safety net (before anything else).** On the old VM:
`openclaw backup create --verify` plus a file-state tarball (`~/brain` without
`node_modules`, `~/.wacli`, `~/.ssh` deploy key + `config` + `authorized_keys`,
`~/ops`, the retired/stale dirs). Both copied to the host, mode 600. Plus
`tart clone vm-claw vm-claw-pre-linux` (APFS copy-on-write, near-zero space).
Record the baseline the acceptance checklist compares against: `openclaw doctor
--non-interactive --allow-exec` output, `openclaw automations list --json`,
`openclaw secrets audit --allow-exec`.

**Step 1 — rehearsal (no downtime).** Build and provision `claw`, import a fresh
export **without** the WhatsApp credentials (`~/.openclaw/credentials/whatsapp`,
`~/.wacli/session.db`) and **with the cron scheduler disabled**. Two gateways
presenting the same WhatsApp device keys risk logging the devices out, and two
schedulers would double-send every announce. The rehearsal must pass everything
in the acceptance checklist that does not need WhatsApp or cron. Then it is
discarded.

**Step 2 — cutover (15–30 min downtime, owner present).**

1. Old VM: stop the gateway and the listener guard.
2. Old VM: final `openclaw backup create --verify` and file-state tarball,
   *including* both WhatsApp credential sets. Moving them only after the old
   gateway is stopped keeps the same linked devices — no QR re-pairing and no
   history backfill.
3. Rename the old Tailscale node to `vm-claw-tart`, shut the Tart VM down,
   disable its launchd agent.
4. New VM, `import.sh`:
   - restore `~/.openclaw` with `openclaw backup` and the file-state tarball;
     `npm ci` in `~/brain/harvester`;
   - rewrite **binary** paths only (`/opt/homebrew/bin/<x>`,
     `/opt/homebrew/opt/node@24/bin/node` → the Debian location of `<x>`), and
     only in structured JSON: `openclaw.json` (secret providers' `command` and
     `trustedDirs`), the cron store, the harvester config. Home paths are not
     rewritten anywhere (see Paths below);
   - fail unless every absolute executable path in those JSON files exists and
     is not a symlink into another directory (the exec providers' `trustedDirs`
     check compares resolved paths), and every `/opt/homebrew/bin/<x>` named in
     free text (`~/brain` prompts and scripts, workspace skills, `~/ops`)
     resolves through a compatibility symlink;
   - disable the iMessage plugin and remove its channel config;
   - `openclaw doctor --fix` with the gateway stopped, then start it.
5. Host: remove the tunnel agent; the face reconnects through the port forward.

**Paths.** The state databases hold ~61k absolute `/Users/admin/…` strings
(state DB ~9.4k, `main` agent DB ~52k, `vera` ~150): session file locations,
workspace paths, plugin install records and transcript history, some inside
compressed rows. Rewriting them is how a database gets corrupted, so the Linux
home is a real directory at `/Users/admin` and no home path changes. A symlink
`/Users/admin` → `/home/admin` was rejected: OpenClaw writes new paths from
`$HOME` and compares stored paths to computed ones, so two spellings of one
directory would fail containment and equality checks intermittently. Binaries
are the opposite case: they live elsewhere on Debian, so structured config
points at their real locations (safe, JSON-aware, testable), and
`/opt/homebrew/bin/` symlinks exist only as a safety net for commands an agent
might read in a prompt or note and execute literally. Repo scripts never
hard-code `/home` or `/Users`; they use `$HOME`.

The legacy plaintext OpenAI profile was already removed (2026-09-30, key
revoked); `secrets audit` is clean going in.

**Acceptance checklist — cutover is not done until every item passes:**

- [ ] `openclaw secrets audit --allow-exec`: 0 unresolved.
- [ ] `openclaw update status --json`: last run `succeeded`; `doctor` shows no new
      warnings versus the pre-migration baseline.
- [ ] WhatsApp linked and connected; one real inbound message gets a reply.
- [ ] `wacli auth status`: authenticated; a manual `ocsb-harvest` run reports
      `ok:true`.
- [ ] First scheduled runs of `ocsb-ingest` and one announce job succeed.
- [ ] Memory search returns results; agent probes answer on the primary
      (DeepSeek) and the fallback (luna).
- [ ] Face appears in gateway presence as `gateway-client`; a voice-gateway
      `chat.send` round-trips.
- [ ] Vault commit pushes with the deploy key.
- [ ] `ssh admin@vm-claw` over Tailscale; `limactl shell claw` from the host.
- [ ] Firewall: from the guest, a LAN address is unreachable and the internet is
      reachable.
- [ ] Listener guard replays a recorded stranded-listener log and would restart.
- [ ] A nightly backup restores into a scratch VM (restore drill).

**Rollback (2-week window).** `limactl stop claw`; copy the WhatsApp and wacli
credentials back to the old VM (they change as messages flow); re-enable the
tunnel agent and the Tart launchd agent; start the old VM. State created only in
the new VM (messages, sessions) is lost unless exported back the same way.
After two weeks without rollback: delete the Tart VM, its clone, the Tart
scripts and the Tart launchd agent.

### 4. Operations

**Backups — today nothing leaves the VM.**

- Nightly in the guest (systemd timer, 03:30, after `ocsb-research`):
  `openclaw backup create --verify` plus the file-state tarball into
  `~/backups`, keep 7.
- Nightly on the host: a launchd job pulls the newest pair over Lima's SSH into
  `~/Backups/vm-claw/`, keep 14. Direction is always host → VM; the guest never
  gets write access to the host. The host disk is not FileVault-encrypted, so
  the off-site copy below is the one that is encrypted at rest.
- Off-site: a restic repository (encrypted, deduplicated) in the host's iCloud
  Drive, password in 1Password, run after the pull.

**Upgrades.**

- Debian security: `unattended-upgrades`.
- OpenClaw: `openclaw update`, as today.
- Debian major (~every 2 years): in place (`apt full-upgrade`) or rebuild —
  new instance from the new image, `provision.sh`, export/import cutover. Both
  in the runbook.
- Lima: `brew upgrade lima`; `claw.yaml` is unaffected.

**Reboots.** The host auto-logs in (FileVault off since 2026-09-30), and the VM
starts at login via `limactl start-at-login`, so a host reboot or power cut
recovers unattended: face, VM and voice-gateway all come back without a console
login. The trade-off, accepted by the owner: the host disk, including the VM
image and its secrets, is not FileVault-protected at rest. The gateway unit restarts on failure; the listener guard keeps
covering the OpenClaw stranded-listener bug.

### 5. Testing

- `shellcheck` on every script.
- `provision.sh` idempotency: a second run changes nothing.
- Binary-path rewrite fixture test: an old-style config in; every executable
  path out points at a real Debian binary; home paths and all non-executable
  strings unchanged byte-for-byte.
- Listener guard replay tests move with the guard.
- The rehearsal (§3, step 1) is the integration test; the acceptance checklist
  is the gate.

## Verification before build

Facts the plan's first task must establish, each with its fallback:

| Fact | Fallback |
|---|---|
| `wacli 0.13.0` ships a linux-arm64 build | build that tag from source (Go) |
| `sag 0.3.0` ships a linux-arm64 build | build from source |
| `openclaw backup` has a restore path that works across OSes | restore the tarball manually into `~/.openclaw`, then `doctor --fix` |
| The wacli store and session (created on macOS) open on Linux | re-pair wacli once; the store is still copied |
| OpenClaw's structured log path on Linux (the guard reads `/tmp/openclaw` today) | point the guard at the Linux path |
| Lima `vz` NAT gateway address, for the DNS exception in the firewall | derive at provision time from the default route |
| Host RAM supports 8 GiB for the guest | size down to 6 GiB |
| Where OpenClaw's browser plugin finds Chromium on Debian | set the executable path in config |

## Risks

- **WhatsApp device logout.** Mitigated by never running two gateways with the
  same credentials: the rehearsal excludes them, and they move only after the
  old gateway stops.
- **Hidden macOS assumptions in state** (`launchctl`, `open`, `osascript` in
  cron commands, prompts or skills). Home paths are neutralised by keeping
  `/Users/admin`; binary paths by the rewrite plus symlinks; the import gate
  greps `~/brain`, workspace skills and `~/ops` for macOS-only commands and fails
  on any hit that is not explicitly allow-listed.
- **Silent data loss.** Mitigated by the Step 0 snapshot, the 2-week rollback
  window, and the restore drill in acceptance.
