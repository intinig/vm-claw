# Bot user `sebastian`: design addendum

Date: 2026-10-02. This addendum extends `2026-09-30-linux-vm-migration-design.md`. That spec still governs everything this document does not change.

## Why

The Linux guest runs the OpenClaw gateway, and with it the agent's exec tools, as `admin`. `admin` is Lima's login user and has passwordless `sudo`, and the gateway unit sets `NoNewPrivileges=no`. That makes the agent root-capable. It could, for example, delete the nftables egress table and reach the LAN.

Running the bot as `admin` was carried over from the original VM setup. It was never a choice. The final review of the migration branch raised this as I-5. The owner chose a dedicated, unprivileged account for the bot.

## Goals

1. The gateway, the agent's tools, the listener guard, the nightly backup and all bot data run as `sebastian`. `sebastian` is an account with no `sudo` and no administrative rights.
2. `admin` stays Lima's login and maintenance user with `sudo`, and owns none of the bot's data or services.
3. The egress firewall becomes a real boundary against the agent: `sebastian` cannot become root, so it cannot change the firewall.
4. Everything else behaves as it does today:
   - isolation (no mounts, one forward);
   - nightly backup, host pull, restic, backup-health alert;
   - Tailscale Serve and SSH;
   - the face's connection on `127.0.0.1:18789`;
   - WhatsApp without relinking.
5. The final review's runbook and acceptance findings (I-1, I-3, I-4) and the promoted minors (#41, #54) are fixed as part of this work.

## Non-goals

- Changing the Lima VM definition, the firewall rules or the port forward.
- Restricting `admin`'s `sudo`. `admin` is the maintenance identity, and the owner works as `admin`.
- Rewriting historical paths inside chat transcripts. Old transcripts may keep `/Users/admin` in tool output. Only live configuration matters.
- Retiring Tart (Task 14 is unchanged).

## Decisions (owner, 2026-10-02)

| Decision | Choice |
|---|---|
| Bot account name | `sebastian` |
| Bot home | `/home/sebastian` |
| Approach | In place on the live guest (A). Not a fresh VM, not a manual file move. |
| Host helper name | `host/claw.sh sebastian -- <cmd>` |
| Independent review fixes | I-2 and I-6 shipped separately (`2f36361`, `71f60ce`, `eba64ff`). I-1, I-3 and I-4 fold in here. |

## 1. Accounts and permissions

- **`admin`.** Unchanged as Lima's login user, used by `limactl shell`, SSH over Tailscale and provisioning, with passwordless `sudo`. After the switch it owns no bot data and no bot units, and linger is disabled for it.
- **`sebastian`.** Created by provisioning:
  - **Identity:** UID and GID 2000, home `/home/sebastian` at mode 700, shell `/bin/bash`, password locked. 2000, not 1001: the 1password-cli package claims the first free GID (1001) for its setgid `op` group.
  - **No privileges:** member of its own group only. No `sudo`, and provisioning asserts that `sudo -l -U sebastian` grants nothing.
  - **Linger enabled,** so its user units start at boot.
  - **No SSH login:** no `authorized_keys`, and `DenyUsers sebastian` in sshd. Reach it from `admin` with `sudo -iu sebastian`.
- **Tailscale.** `tailscale set --operator=sebastian`, so the gateway can manage its Serve claim (`gateway.tailscale.mode=serve`) without root. Today that works only through `admin`'s passwordless `sudo`. `tailscaled` stays a root system service.
- **Firewall.** Unchanged, and only root can alter it.

What `sebastian` owns: `~/.openclaw`, `~/brain` (the vault and its deploy key under `~/.ssh`), `~/.wacli`, `~/ops`, `~/backups`, and the user units `openclaw-gateway.service`, `openclaw-listener-guard.{service,timer}` and `openclaw-nightly-backup.{service,timer}`.

## 2. The switch (in place)

**Before the downtime,** with production running:

1. Re-run provisioning on the live guest. It is idempotent, and since I-6 it never downgrades OpenClaw. It creates `sebastian`, linger, the sshd `DenyUsers` and the Tailscale operator setting.
2. Install the repo read-only at `/opt/vm-claw`, root-owned and world-readable. `sebastian` runs scripts from there.

**Downtime, about 15 minutes:**

1. As `admin`, stop and disable the gateway, the listener guard (service and timer) and the nightly timer. Assert that the gateway is `inactive` or `failed`.
2. Run one nightly backup as `admin` with the gateway stopped, so it is a consistent snapshot.
3. Copy that nightly into `/home/sebastian/claw-import/`, owned by `sebastian`, mode 700.
4. As `sebastian`, run `import.sh final` on it. The import gains two behaviours:
   - **Home rewrite.** In structured configuration, replace every `/Users/admin` prefix with `$HOME`. That covers `openclaw.json` (the secret-provider command path and trusted dirs, the workspace paths, the vault path), the automations store, and skill and `~/ops` configs. The free-text scan is extended so that any `/Users/admin` left in live configuration fails the import. Chat transcripts are excluded.
   - **No login keys for the bot.** When the importing user is not the archive's original user, `.ssh/authorized_keys` is not installed. Only the vault deploy key, `config` and `known_hosts` are.
5. Run `acceptance.sh final` as `sebastian`. It now also asserts that `sebastian` has no `sudo` and that no bot process runs as `admin`. Downtime ends when it passes.
6. Retire `admin`'s copy. Move `admin`'s `~/.openclaw`, `~/brain`, `~/.wacli`, `~/ops`, `~/backups`, `~/claw-import` and its bot user units to `/var/lib/claw-retired-admin-<date>/`, root-owned at mode 700. Disable `admin`'s linger. The copy is deleted after 14 days. `admin`'s own `~/.ssh/authorized_keys` stays.

**Rollback.**
- **Until step 6:** re-enable `admin`'s three units. This takes under a minute, because `admin`'s data has not been touched.
- **Within 14 days after step 6:** restore the retired copy, as documented in the README.
- **Tart rollback:** still available until Task 14, with its runbook updated for the new paths.

## 3. Host access and tooling

- **`host/claw.sh`:**
  - `shell` stays `admin`.
  - The new `sebastian -- <cmd>` runs a command as `sebastian` with a proper user-session environment (`XDG_RUNTIME_DIR`, the D-Bus address), so `openclaw`, `systemctl --user` and `journalctl --user` work.
  - `CLAW_INSTANCE` (default `claw`) selects the instance, for drills and rebuilds.
- **`host/pull-backups.sh`.**
  - The host can no longer read the backups directly. It lists `/home/sebastian/backups` and streams each night with `sudo -u sebastian tar -C … -cf - <night> | tar -xf -` into the existing `.partial` directory.
  - Unchanged: the checksum gate, the lock, failed-night handling, per-night restic snapshots, retention and the staleness alarm.
  - The success stamp is written as `sebastian`.
- **`tests/acceptance.sh`** runs as `sebastian` and adds the following (fixes I-1):
  - **Privilege items:** no `sudo` for `sebastian`; no bot process owned by `admin`.
  - **Guard replay:** a committed stranded-listener log fixture replayed through `guard.mjs --dry-run --now <ts>` must print `[dry-run] … restart:`. `guard.mjs --now` without `--dry-run` must refuse to restart (promoted minor #41).
  - **MANUAL lines:**
    - `doctor` versus the pre-migration baseline (run on a drill, because `doctor` writes);
    - memory search (`openclaw memory search … --agent main`);
    - `ssh admin@vm-claw` over Tailscale, and `limactl shell claw`;
    - a voice round-trip;
    - a vault commit pushed since cutover.
  - **LAN-address argument:** reject `0.0.0.0` and `127.0.0.1` (promoted minor #54).
- **`migrate/import.sh`.** The home rewrite and authorized_keys rule from section 2. The closing hint names only valid acceptance modes.
- **Docs.** The README and CLAUDE.md are rewritten for the two-account layout and fold in:
  - **I-3, rollback:** the guard service is included; it proves the gateway is down; it moves old WhatsApp/wacli files aside before copying (including `-wal`/`-shm`); it uses `mkdir -m 700`; and it names the SSH targets and plists.
  - **I-4, rehearse and rebuild:**
    - rehearse with `drill`;
    - rebuild from a nightly taken with the gateway stopped, then `import.sh final`;
    - restore from restic (repository path, `restic restore latest --target …`, password in the owner's private vault).

## 4. Testing, rehearsal, rollout

- **Unit tests** (fakes, `make unit`):
  - `claw.sh sebastian` argument and environment handling, plus `CLAW_INSTANCE`;
  - the import home rewrite and leftover scan;
  - the authorized_keys rule;
  - streaming in `pull-backups.sh`, with every existing guarantee;
  - the new acceptance items and the guard-replay fixture.
- **Provisioned-guest checks** (`tests/stack-check.sh`): `sebastian` exists with UID 2000, no `sudo`, linger, `DenyUsers`, and the Tailscale operator setting.
- **Rehearsal** on `CLAW_INSTANCE=claw-drill`, provisioned from scratch:
  1. Import the newest real nightly as `admin`, the old way, to reproduce production.
  2. Run the switch procedure exactly as planned, in drill mode: WhatsApp stripped, cron off.
  3. Run acceptance as `sebastian`, and the `doctor`-versus-baseline comparison.
  4. Reboot the drill once, and confirm that `sebastian`'s units start without a login.

  Without a Tailscale login the drill cannot exercise Serve or live WhatsApp. Production acceptance covers both. Record the results in `docs/verification.md`, then destroy the drill.
- **Production switch** while the owner is reachable for the MANUAL lines: a WhatsApp reply, the face on the panel, a voice round-trip.
- **Review:** each task gets a task review, then the new range gets a final review, before the branch merges.

## Success criteria

1. In the guest, `sudo -n true` fails for `sebastian`. Every gateway, guard, backup and agent-tool process runs as `sebastian`. `sebastian` cannot modify the `inet claw` table.
2. `acceptance.sh final` passes as `sebastian`. Backups, the pull, restic and the alert behave as before.
3. `admin`'s home holds no bot state. The retired copy is root-only and has a deletion date.
4. The rehearsal passed before production.
5. The README rollback, rebuild and restore sections can be followed as written.

## Risks

- **Absolute paths OpenClaw stores elsewhere.** The import's leftover scan fails closed, and the rehearsal surfaces any such path before production. `OPENCLAW_STATE_DIR` relocation is documented upstream.
- **Gateway behaviour as a non-sudo user.** For example, managed self-updates of a root-owned global npm install would no longer work. Updates become a deliberate maintenance action as `admin` (README "Upgrades").
- **Linger or session environment for `sebastian` set up wrong.** Units then don't start at boot. The rehearsal reboots the drill once to prove they do.

## Addendum 2026-10-05: OpenClaw state-path migration (found in the rehearsal)

The rehearsal showed that OpenClaw 2026.9.7 keys parts of its SQLite state by absolute path. The cron store key is `<home>/.openclaw/cron/jobs.json`, and workspace identity, the exec-approvals socket, memory and plugin state keys are absolute too. After a plain import into `/home/sebastian`, all automations were invisible to the new gateway, the workspace registered as new, and Workshop proposals went stale. OpenClaw has no supported relocation for this. `doctor --lint` does not see it, and its upstream "move to a new machine" guide assumes the same recorded path.

Owner decisions (2026-10-05):

- **One-time, version-pinned rewrite.** This applies only to a cross-home import (`import.sh`), with the gateway stopped, before the first `openclaw` command.
  - It rewrites `/Users/admin` → `/home/sebastian` in the functional path-key columns and recomputes the values derived from them (for example, workspace-hashed plugin-state keys).
  - It leaves transcripts and history as they are.
  - It refuses to run on any other OpenClaw version, and on state the new home already touched.
  - It fails the import closed if any table outside the history allow-list still names the old home.
- **File content rewritten at import.** These move to the new home:
  - the memory project annotations (`<!-- project: path:… -->`, absolute by design);
  - Codex's project trust (`codex-home/config.toml`);
  - the Workshop skills (`agents/*/agent/workshop-skills/*/SKILL.md`);
  - the workspace scripts.
  Their folders join the leftover scan.
- **Old config backups moved aside, never deleted.** These are admin's `openclaw.json` backups (`.last-good`, `.bak*`, `.pre-*`, `.clobbered.*`). The auto-restore must not bring back admin's config.
- **Checked after the first start.**
  - The automation count equals admin's count recorded by the switch.
  - No duplicate cron declarations.
  - The workspace rows and the exec-approvals socket are under the new home.
