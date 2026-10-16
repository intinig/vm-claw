# vm-claw

A security-isolated Linux VM that runs an [OpenClaw](https://github.com/openclaw/openclaw) gateway on a Mac mini host. The VM is a [Lima](https://lima-vm.io) instance named `claw` (Debian 13 arm64, `vz` backend, 4 vCPU, 8 GiB RAM, UTC). It replaced a Tart macOS VM on 2026-10-01. The production switch ("Move the bot to its own account") moves the bot from `admin` to its own unprivileged account; `docs/verification.md` records when it ran. The designs are `docs/superpowers/specs/2026-09-30-linux-vm-migration-design.md` and its addendum `docs/superpowers/specs/2026-10-02-bot-user-sebastian-design.md`; the facts the build relies on are in `docs/verification.md`.

This repo is public. It holds no secrets, IPs, phone numbers, WhatsApp JIDs, account names or key fragments, and neither may anything you add to it. Placeholders in this file: `<host>` is the Mac mini's SSH target, `<lan-router-ip>` is any address on the home LAN (used only to prove the guest cannot reach it), `<owner-number>` is the owner's WhatsApp number, `<name>` is the guest's Tailscale hostname, `<ts>` is a nightly's UTC timestamp (`20261002T033000Z`), `<date>` is a day (`20261002`).

**Which layout the guest has.** Until the production switch has run, the guest still runs the earlier layout and tooling (the bot as `admin`, no `sebastian` units, no `/opt/vm-claw`). For Restore, Upgrades or Rebuild in that time, follow the README in the checkout the appliance deployed from, before you update that checkout for the switch, not this file. From the switch on, the bot's units and state belong to `sebastian` and `host/claw.sh sebastian --` is the way in. After a rollback of the switch, admin's units run again but provisioning has already made `sebastian` Tailscale's operator and installed `/opt/vm-claw`, so an admin-side `import.sh final` refuses while Serve is configured (its operator check wants the importing account, `import.sh` "Tailscale's operator must be"): for a restore as admin, first run `host/claw.sh shell -- sudo tailscale set --operator=admin`, and afterwards `host/claw.sh provision` to give the operator back to `sebastian`. (Serve cannot be switched off for a final import; only `rehearsal` and `drill` imports do that.) Run `host/claw.sh provision` after a rollback only from a checkout whose `provision/versions.env` matches the pin that provisioned the guest before the switch (`grep OPENCLAW provision/versions.env` against `host/claw.sh shell -- openclaw --version`): a newer pin makes provisioning run `npm install -g` under admin's running gateway. Under the wrong account a command does not fail loudly: `systemctl --user is-active` on a unit that account does not have prints `inactive`, so a manual stop that must be proved down is also checked for any gateway or guard process under any user (the `ps` line in "Upgrades").

## Overview

Isolation properties, each enforced in `lima/claw.yaml` or by provisioning and each checked by a script in `tests/`:

- No host mounts (`mounts: []`; Lima mounts the host home by default).
- Exactly one port forward: guest `127.0.0.1:18789` to host `127.0.0.1:18789`, then a catch-all ignore (Lima forwards every listening port by default). The appliance face connects to `ws://127.0.0.1:18789` through it.
- NAT only: the guest has no LAN address.
- Guest egress firewall (nftables): RFC1918 and link-local are dropped; loopback, established traffic, DNS and DHCP to Lima's gateway, the internet and Tailscale's `100.64.0.0/10` are allowed.
- No GUI, so no clipboard. `sshd` is key-only.
- Backups leave the VM by a host-to-guest pull only; the guest has no write access to the host.

Two accounts in the guest (from the switch on; before it the bot's units run as `admin`):

- `admin` is Lima's login and maintenance user: `limactl shell`, `ssh admin@<name>` over Tailscale, provisioning. It has passwordless sudo (Lima's cloud-init) and its home is `/Users/admin`. It owns no bot data and no bot units.
- `sebastian` is the bot: UID and GID 2000, home `/home/sebastian` at mode 700, password locked, its own group only, no sudo, no SSH login (`DenyUsers sebastian`, no `authorized_keys`). The gateway, the agent's tools, the listener guard and the nightly backup run as its systemd user units; linger starts them at boot without a login. It owns `~/.openclaw`, `~/brain` (the vault, with its deploy key in `~/.ssh`), `~/.wacli`, `~/ops` and `~/backups`.
- The bot account never gets an SSH login from an import either. `import.sh` refuses a pre-existing symlinked `~/.ssh`, and a symlink at or under `.ssh` in another home's archive. From another home's archive only `ocsb_vault`, `ocsb_vault.pub`, `config` and `known_hosts` land in `~/.ssh`; `authorized_keys` is never installed, and one already in the bot's `~/.ssh` makes the import refuse.
- The bot cannot become root, so the egress firewall holds against the agent too: only root can change the `inet claw` table. `tests/acceptance.sh` proves both on every run (the privilege item, "cannot become root or touch the firewall", passes the firewall half only on a real "Operation not permitted" denial from `nft`; a missing table or a broken `nft` proves nothing and fails).
- Tailscale's operator is `sebastian`, so the gateway manages its own Serve claim (`gateway.tailscale.mode=serve`) without root. `tailscaled` stays a root service.
- The repo is deployed at `/opt/vm-claw`, root-owned and read-only for everyone else. The bot runs its scripts from there.

Pinned versions (`provision/versions.env`): OpenClaw `2026.10.2` (a floor), node major `24`, wacli `0.13.0`, sag `0.4.0`.

## Layout

```
Makefile                                 lint (shellcheck) + unit (node --test and the bash suites)
lima/claw.yaml                           VM definition
host/claw.sh                             host wrapper: create | deploy | provision | start | stop | shell | sebastian | destroy
host/install.sh                          host setup: Lima, restic, the backup pull agent (re-runnable)
host/pull-backups.sh                     host: pull the bot's nightlies, keep 14, restic off-site
host/local.vm-claw.pull-backups.plist    host launchd schedule for pull-backups.sh
provision/bot.sh                         the bot account: name, ids, home, the user-session prefix
provision/lib.sh                         step and assert helpers + change counter
provision/versions.env                   pinned versions and release checksums
provision/nftables.conf.tmpl             egress firewall template
provision/provision.sh                   guest provisioning (root), idempotent
migrate/export.sh                        old Tart VM: backup + file-state + manifest
migrate/import.sh                        guest, as the bot: verify, restore, rewrite, gate, start
migrate/binpaths.mjs                     binary-path rewrite (pure functions + CLI)
migrate/homepaths.mjs                    old-home rewrite of live configuration (pure functions + CLI)
migrate/scan-refs.mjs                    free-text scan: Homebrew paths, macOS-only commands, an old home
migrate/lib/home-roots.sh                the live-configuration roots that import.sh and rehome.sh scan
migrate/rehome.sh                        the in-place move to the bot account: prepare | switch | verify | retire | rollback
ops/listener-guard/                      stranded-listener guard, its systemd user units, a replay fixture
ops/backup/                              guest nightly backup, its units, backup-health.mjs
ops/lib/dotenv-token.sh                  shared parser for the bootstrap token in ~/.openclaw/.env
tests/isolation-check.sh                 host-side: mounts, forwards, no LAN address
tests/firewall-check.sh                  guest-side: LAN blocked, internet + DNS OK
tests/stack-check.sh                     guest-side, as admin: pinned tools, the bot account, the deployed repo
tests/acceptance.sh                      guest-side, as the bot: the acceptance checklist
docs/verification.md                     verified facts and the rehearsal, switch and drill records
```

The checkout can live at any path on the host; the pull agent's plist gets that path from `host/install.sh`'s own location. Update it with `git pull` before `host/claw.sh deploy`.

## Build

On a Mac with Lima (`brew install lima`):

```bash
host/claw.sh create            # 8 GiB by default; --memory <GiB> to change
host/claw.sh start
host/claw.sh provision         # deploys HEAD to /opt/vm-claw, then provisions as root; a second run changes nothing
host/claw.sh shell -- bash /opt/vm-claw/tests/stack-check.sh
tests/isolation-check.sh       # host side; exit 1 on any violation
host/claw.sh shell -- bash /opt/vm-claw/tests/firewall-check.sh <lan-router-ip>
```

`CLAW_INSTANCE=<instance>` in front of any host script (`host/claw.sh`, `host/install.sh`, `host/pull-backups.sh`, `tests/isolation-check.sh`) picks another instance, for a drill or a rebuild; the default is `claw`. Other `host/claw.sh` commands: `stop`, `destroy`, `deploy` (ships HEAD only: commit first), `shell [-- cmd]` (as admin) and `sebastian -- <cmd>` (as the bot, with `XDG_RUNTIME_DIR` and the D-Bus address set, so `systemctl --user`, `journalctl --user` and `openclaw` work). Inside the guest, admin reaches the bot's files with `sudo -iu sebastian`; that shell has no `XDG_RUNTIME_DIR`, so `systemctl --user` fails there: use `host/claw.sh sebastian --` for anything systemd. Plain `limactl shell` and `ssh admin@<name>` land as admin, whose `systemctl --user` has none of the bot's units.

Never run git inside the guest: a worktree's `.git` file does not resolve there. The guest gets the repo only through `host/claw.sh deploy`. `import.sh` installs `ops/` into the bot's `~/ops`; a later change to `ops/` reaches it in two steps: `host/claw.sh deploy`, then copy the changed file as the bot, for example `host/claw.sh sebastian -- cp /opt/vm-claw/ops/listener-guard/guard.mjs ops/listener-guard/`, and `host/claw.sh sebastian -- systemctl --user daemon-reload` after a unit change.

Tailscale: `gateway.tailscale.mode=serve` needs a logged-in Tailscale in the guest, and the gateway will not start logged out. Join with:

```bash
host/claw.sh shell -- sudo tailscale up --hostname=<name> --advertise-tags=<same tag as the old node>
host/claw.sh provision         # again: it sets the Tailscale operator to sebastian once Tailscale is logged in
```

The same tag keeps the node under the same ACLs and without key expiry.

## Move the bot to its own account

The guest first ran the bot as admin. `migrate/rehome.sh` moves it to the bot account in place, in phases; each refuses when the one before has not completed. Run them as admin: `host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh <phase>`. Every phase takes the exclusive lock `/run/lock/claw-rehome.lock` once its arguments check out, so only one runs at a time (a second one says "another rehome.sh is running"). The completed phases are recorded in `/var/lib/claw-rehome/` (root only): `switched`, `imported`, `verified`, `retired` and, after a rollback, `rolled-back-<ts>`. A phase that stops on an unexpected error prints where it stopped and which records exist.

1. Before the downtime, with production running: update the host's checkout, then `host/claw.sh provision` (creates `sebastian`, linger, `DenyUsers`, the Tailscale operator and `/opt/vm-claw`), `host/claw.sh shell -- bash /opt/vm-claw/tests/stack-check.sh`, then `host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh prepare`. Do all of it, up to and including the switch, on the same day: once the host's checkout has this branch, the pull agent reads only the bot's `/home/sebastian/backups` and stops pulling admin's nights. The switch's own night goes to the bot's `claw-import`, not to `backups`: the bot's `backups` fills only from the bot's 03:30 UTC timer, which `import.sh final` installs, so the first pulled night is the one after the switch. `prepare` changes nothing in production: it checks the bot account, the deployed repo, the Tailscale operator when serve is configured, and the free space, then runs a dry leftover scan of admin's live configuration (what `import.sh` would refuse mid-downtime), walks admin's workspace notes as the import's annotation rewrite will (a symlinked directory there fails), and runs `migrate/state-paths.py preflight`: python 3.9+ with sqlite3, the OpenClaw 2026.9.7 pin, and a dry run of the state-path migration on read-only copies of admin's live databases. The scan and the preflight work on scratch copies under `/tmp`, which is tmpfs on Debian 13, so they cost RAM for the size of `brain` minus its vault, `.git` and `node_modules`, plus `~/.openclaw/state/openclaw.sqlite` and the Codex `state_5.sqlite` files; the copies are removed on every way out. Plan the downtime after the 09:00 backup check and well before the 03:30 UTC nightly.
2. `rehome.sh switch final` (the downtime starts; expect about 15 minutes in all, to the end of step 3): it runs `prepare` again, records the automation count admin's gateway lists (`cron-total`; a count it cannot read stops the switch before anything is stopped), stops and disables admin's gateway, guard and nightly timer and proves them inactive, sets admin's gateway logs aside, takes one nightly with the gateway stopped, copies it to `/home/sebastian/claw-import/`, and runs `import.sh final` as the bot. Before any `openclaw` command, the import moves OpenClaw's path-keyed SQLite state (`migrate/state-paths.py`: OpenClaw 2026.9.7 only, fails closed). It rewrites `/Users/admin` to `/home/sebastian` in live configuration, Codex's project trust, the Workshop skills, the workspace scripts and the memory project annotations, moves admin's `openclaw.json` backups to `~/.openclaw/pre-rehome-config-backups/`, fails on anything left over, and installs no `authorized_keys`. Old transcripts keep their history. `switched` is recorded before the import and `imported` after it; if the import fails, admin's data is untouched and `rehome.sh rollback` brings admin's gateway back.
3. `rehome.sh verify final <lan-router-ip>` runs `tests/acceptance.sh final` as the bot, then compares the bot gateway's own automation count (`openclaw cron list --all --json`) with the one the switch recorded, and runs `migrate/state-paths.py check`: that count in the migrated cron store, no cron row under another store key, no duplicate cron declarations, the workspace rows and the exec-approvals socket under the new home, and the Workshop proposals' statuses unchanged. It needs the `imported` record and the same mode as the switch (`final` for `final`, `rehearsal` for `drill`). The owner confirms the `MANUAL` lines. The downtime ends when it passes (`verified` is recorded). Decision rule: an automated FAIL that cannot be fixed within about 15 minutes means `rehome.sh rollback`, not a longer downtime.

   **3a.** Before relying on the 06:15 run, prove the pull as the bot on the real guest. Trigger one bot nightly by hand: `host/claw.sh sebastian -- systemctl --user start openclaw-nightly-backup.service` (it returns when the oneshot ends). Then, on the host, run `bash host/pull-backups.sh` by hand and confirm the new night is in `~/Backups/vm-claw` and in restic: `ls ~/Backups/vm-claw | tail -2`, and with the restic environment from "Restore from restic", `restic snapshots --tag vm-claw | tail -2`. Only then is the unattended run trusted.
4. `rehome.sh retire` runs only after the owner has confirmed every `MANUAL` line. It needs `verified` and the bot's gateway active. It stops admin's units again, then writes `RETIRING` in `/var/lib/claw-retired-admin-<date>/` (root only) before its first move, moves admin's copy there, turns admin's linger off, and renames `RETIRING` to `RETIRED` as its last step. It refuses to run twice. If it dies half-way, see "A half-done retire" under "Rollback". Delete the copy after 14 days ("Retire").

Rehearse the whole sequence on a drill first ("Rehearse the move"), with `switch drill` and `verify rehearsal <lan-router-ip>`. Until `retire`, `rehome.sh rollback` takes under a minute; after it, within 14 days, `rehome.sh rollback` restores the retired copy ("Rollback").

Acceptance differs by mode in two places that matter here. The guard replay (the installed guard on a committed stranded-listener log) must decide `restart:` in `final`; in `rehearsal` it must report WhatsApp unlinked (`skip: WhatsApp not linked`), and a `restart:` there fails the item, because it means the drill's credentials were not stripped and a second gateway could take WhatsApp. And the privilege item passes its firewall half only on a real "Operation not permitted" denial from `nft`.

## Migrate (from the Tart VM, 2026-10-01)

`migrate/export.sh rehearsal|final` runs on the old VM and writes `~/claw-export-<mode>-<UTC ts>/` (two archives and a `MANIFEST` that starts with `mode=<mode>`). `migrate/import.sh rehearsal|final|drill <export-dir> [--force]` runs in the guest as the bot (`host/claw.sh sebastian -- bash /opt/vm-claw/migrate/import.sh …`) and verifies every checksum before touching `$HOME`. It refuses to run as root, and without a systemd user manager for the account that runs it (under `host/claw.sh sebastian --` that is the bot's, which its linger keeps up).

- `rehearsal`: the export must carry no WhatsApp credentials; cron stays off and Tailscale serve is switched off. No real archive passes it, because `openclaw backup` always includes `credentials/whatsapp`: rehearse with `drill` ("Rehearse").
- `final`: carries the WhatsApp and wacli credentials, cron stays on, and with serve configured it needs a running, logged-in Tailscale whose operator is the importing account. It refuses a `mode=rehearsal` archive and accepts `mode=nightly`.
- `drill`: restores any archive for a restore drill, strips both credential sets and disables cron before anything starts.
- An archive made under another home is rehomed: that home is rewritten to `$HOME` in live configuration (`migrate/homepaths.mjs`), anything still naming it in live configuration fails the import (`migrate/scan-refs.mjs --old-home`), and its `authorized_keys` is not installed.
- Re-running on a guest that already has state is refused without `--force`, which moves `~/.openclaw` aside.

Never run two gateways with the same WhatsApp credentials.

The cutover from Tart (about 6 minutes of downtime) ran as admin: the old VM's `export.sh final`, a safety copy on the host, the old Tailscale node renamed `<name>-tart`, the host's SSH gateway-tunnel launch agent and the Tart launch agent disabled (plists renamed to `.disabled`), the guest given 8 GiB and its node renamed `<name>`, the export copied into the guest and imported with `import.sh final`, `limactl autostart enable claw`, `host/install.sh`, then acceptance. A repeat after a rollback to Tart imports into the bot account instead (as in "Rebuild", steps 6 and 7).

`openclaw doctor --non-interactive` writes (it rewrote the macOS service definition). Run it only with the gateway stopped.

### Revoked keys

`openclaw models auth logout` clears only the shared auth store. Provider model-catalog cache rows (`cache_entries`, scope `plugin-model-catalog-v1`) and old `.bak` database snapshots can still hold an old key, and a first start on a new box can rebuild a profile from such a row. The import's `openclaw secrets audit --check` catches it. Clean up with the gateway stopped: delete the row, then `PRAGMA wal_checkpoint(TRUNCATE); VACUUM;`.

## Operate

### Backups

- Guest: the bot's `openclaw-nightly-backup.timer` runs `ops/backup/nightly-backup.sh` nightly into `/home/sebastian/backups/claw-nightly-<ts>` (the same layout as an export, `mode=nightly`, keep 7).
- Host: `host/install.sh` sets up Lima, restic and the `local.vm-claw.pull-backups` launchd agent (its plist carries `CLAW_INSTANCE`). `host/pull-backups.sh` lists the bot's backups and streams each missing night with `sudo -n -u sebastian -- tar -cf -` through `limactl shell` (the backups are the bot's, mode 700) into `~/Backups/vm-claw` (keep 14). A night is kept only if it holds exactly its three files and passes the checksum gate. Every night restic has no snapshot of goes to a restic repository in iCloud Drive as its own snapshot (a night whose backup failed is retried on the next run; set that folder to "Keep Downloaded"), and only after a fully successful run does the pull stamp `/home/sebastian/backups/.host-pull-ok`, as the bot. Run `host/install.sh` over `ssh -t`: storing the restic password prompts on the terminal, and a locked login keychain must be unlocked first.
- Backup growth: the nightlies are gzip'd tarballs, which restic can neither deduplicate across nights nor compress, so each retained night costs its full size (about 1.2 GB today). Forget keeps 14 daily, 8 weekly and 12 monthly snapshots, counted per night (`--group-by host`), so the repository settles at about 34 retained nights, roughly 40 GB at today's size, and grows with the nightly. "Keep Downloaded" mirrors the whole repository on the Mac mini's disk. Check the iCloud storage quota and the host's free disk before relying on it, and again when the nightly grows: a full quota stops the off-site copy without any check failing.
- Alert: `ops/backup/backup-health.mjs` checks both halves. It exits 0 when healthy, 1 with `BACKUP ALERT: ...` when a nightly or the host stamp is older than 30 h, missing or dated in the future, and 2 when it cannot read `~/backups`. An OpenClaw command automation runs it daily at 09:00 Europe/Amsterdam (created at cutover, not committed). The command is a wrapper that prints `NO_REPLY` when the check passes, so nothing is sent, and on any non-zero exit, crash or missing script prints the alert:

  ```bash
  out=$(node "$HOME/ops/backup/backup-health.mjs" 2>&1); rc=$?; if [ "$rc" -eq 0 ]; then echo NO_REPLY; else printf "BACKUP ALERT (exit %s): %s\n" "$rc" "$out"; fi
  ```

  The full invocation, with `$wrapper` holding the line above:

  ```bash
  openclaw automations add --name backup-health --display-name "Backup health" \
    --description "Daily check of guest nightly + host pull/restic stamp; silent when healthy, WhatsApps on any failure" \
    --cron "0 9 * * *" --tz Europe/Amsterdam --exact \
    --command "$wrapper" --timeout-seconds 120 \
    --announce --channel whatsapp --to "<owner-number>" \
    --declaration-key backup-health
  ```

  Check the live wrapper with `host/claw.sh sebastian -- openclaw automations list --json`.

### Upgrades

- Debian security: `unattended-upgrades` (installed by provisioning).
- OpenClaw: the CLI is a root-owned global npm install the bot cannot write, so `openclaw update` cannot replace it; an upgrade is a maintenance action as admin, behind a backup. Bump `OPENCLAW_VERSION` in `provision/versions.env` and commit, then (before the switch, use the earlier checkout's README; after a rollback of the switch, `host/claw.sh shell --` in place of `host/claw.sh sebastian --`):

  ```bash
  host/claw.sh sebastian -- systemctl --user start openclaw-nightly-backup.service       # a nightly first: the way back
  host/claw.sh sebastian -- systemctl --user stop openclaw-listener-guard.timer openclaw-listener-guard.service openclaw-gateway.service
  host/claw.sh sebastian -- systemctl --user is-active openclaw-gateway.service openclaw-listener-guard.service   # both: inactive or failed
  host/claw.sh shell -- bash -c 'ps -eo user:12=,args= | grep -E "openclaw|guard\.mjs" | grep -v grep'   # must print nothing
  host/claw.sh provision                                    # the pin is a floor: installs the newer pin, never downgrades
  host/claw.sh sebastian -- openclaw doctor --non-interactive   # only with the gateway proven down: doctor writes
  host/claw.sh sebastian -- openclaw update repair --yes --no-restart   # updates the bot's plugins to the core's version and finishes the migrations; read its output first
  host/claw.sh sebastian -- systemctl --user start openclaw-gateway.service openclaw-listener-guard.timer
  host/claw.sh sebastian -- bash /opt/vm-claw/tests/acceptance.sh final <lan-router-ip>
  ```

  Before an upgrade, trial-install the new pin as the bot into a scratch prefix with provisioning's `--strict-allow-scripts --allow-scripts=…` list (a global install: `npm install -g --prefix <dir>`, with `<dir>/lib` created first), so a newly blocked install script fails there and not in the downtime. `doctor --non-interactive` applies only safe migrations: the managed plugins (`~/.openclaw/npm`, the bot's) stay on the old version until `update repair` updates them. Do not pass `--accept-capabilities` without reviewing what widened. Any install record or path still pointing into admin's home makes the repair's finalize step fail with `EACCES`; on 2026-10-13 that was the dropped iMessage plugin (`openclaw plugins uninstall imessage --force`).

  After a rollback of the switch, acceptance run as admin (`host/claw.sh shell --`) FAILs exactly one item, "privilege: the bot account cannot become root or touch the firewall", by design: admin has passwordless sudo. Expect that one and nothing else.

  `tests/stack-check.sh` and the acceptance "update status" item pass at or above the pin.
- Debian major, about every two years: in place with `apt full-upgrade` as admin, or a rebuild ("Rebuild").
- Lima: `brew upgrade lima` on the host; `lima/claw.yaml` is unaffected.

### Reboots

The host auto-logs in and `limactl autostart enable claw` starts the VM at login, so a host reboot or power cut recovers unattended. The bot's linger starts its gateway, guard and nightly timer without a login. The gateway unit restarts on failure, and the listener guard restarts it when the WhatsApp listener is stranded.

### Tests

`make lint` (shellcheck), `make unit` (node tests, the state-paths Python tests, plus the bash suites: import, home-roots, rehome, backup, install, claw, acceptance, stack-check, lib, vercmp), `make test` for both and the `/bin/bash` 3.2 runs. The bash suites also pass under `/bin/bash` 3.2.

## Restore

A nightly has the same layout as a final export, so `import.sh final` accepts `mode=nightly`. In place, as the bot (before the switch, use the earlier checkout's README; after a rollback of the switch, as admin: `host/claw.sh shell --` and admin's paths, with the operator step in the intro note):

```bash
host/claw.sh sebastian -- systemctl --user stop openclaw-listener-guard.timer openclaw-listener-guard.service openclaw-nightly-backup.timer openclaw-nightly-backup.service openclaw-gateway.service
host/claw.sh sebastian -- systemctl --user is-active openclaw-gateway.service openclaw-listener-guard.service   # both: inactive or failed
host/claw.sh shell -- bash -c 'ps -eo user:12=,args= | grep -E "openclaw|guard\.mjs" | grep -v grep'   # must print nothing
host/claw.sh sebastian -- bash -c 'mkdir -p -m 700 ~/claw-import && cp -a ~/backups/claw-nightly-<ts> ~/claw-import/'
host/claw.sh sebastian -- bash -c 'a=~/wacli-pre-restore-aside; mkdir -m 700 "$a" && mv ~/.wacli/session.db* "$a"/'
host/claw.sh sebastian -- bash /opt/vm-claw/migrate/import.sh final /home/sebastian/claw-import/claw-nightly-<ts> --force
```

- The copy comes first, so the retained backup is never the import's working copy. `--force` moves the current `~/.openclaw` to `~/.openclaw.pre-import-<ts>`, which holds credentials and several GB: delete it once the restore is accepted. It does not move `~/.wacli`: the night's file state would overwrite `~/.wacli/session.db`, so the wacli session is set aside first (`~/wacli-pre-restore-aside`; it holds a credential too: delete it with the pre-import dir).
- The restore takes both WhatsApp credential sets back to that night, which can force a relink. To keep the live sets instead, stop the units again and prove them down (`import.sh` has just started the gateway), then put the restored sets aside, copy the live ones back and start:

  ```bash
  host/claw.sh sebastian -- systemctl --user stop openclaw-listener-guard.timer openclaw-listener-guard.service openclaw-nightly-backup.timer openclaw-nightly-backup.service openclaw-gateway.service
  host/claw.sh sebastian -- systemctl --user is-active openclaw-gateway.service openclaw-listener-guard.service   # both: inactive or failed
  host/claw.sh shell -- bash -c 'ps -eo user:12=,args= | grep -E "openclaw|guard\.mjs" | grep -v grep'   # must print nothing
  host/claw.sh sebastian -- bash -c 'p=$(ls -d ~/.openclaw.pre-import-* | tail -1); a=~/wa-restored-aside; mkdir -m 700 "$a" && mv ~/.openclaw/credentials/whatsapp* "$a"/ && cp -a "$p"/credentials/whatsapp* ~/.openclaw/credentials/ && mv ~/.wacli/session.db* "$a"/ && cp -a ~/wacli-pre-restore-aside/session.db* ~/.wacli/'
  host/claw.sh sebastian -- systemctl --user start openclaw-gateway.service openclaw-listener-guard.timer openclaw-nightly-backup.timer
  ```

- `import.sh drill <dir>` proves a backup restores without putting a second gateway on the WhatsApp devices. Run drills on a machine other than the appliance: there the host port 18789 belongs to production.
- Backups live in the bot's `~/backups` in the guest, in `~/Backups/vm-claw` on the host and in the restic repository ("Restore from restic").

## Rehearse

A drill restores a real nightly into the bot account of a scratch instance, with both WhatsApp credential sets stripped and cron off. `<drill-input>` is a directory on the dev Mac that holds a night: take one from the host (`scp -rp <host>:~/Backups/vm-claw/claw-nightly-<ts> <drill-input>/`) or from restic (step 1 of "Rehearse the move"). On the dev Mac, never the appliance:

```bash
CLAW_INSTANCE=claw-drill host/claw.sh create --memory 8 && CLAW_INSTANCE=claw-drill host/claw.sh start && CLAW_INSTANCE=claw-drill host/claw.sh provision
CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/tests/stack-check.sh       # stack: OK; the Tailscale operator line is skipped
CLAW_INSTANCE=claw-drill host/claw.sh shell -- mkdir -p -m 700 claw-import
limactl copy --backend=scp -r <drill-input>/claw-nightly-<ts> claw-drill:claw-import/
CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash -c 'sudo install -d -m 700 -o sebastian -g sebastian /home/sebastian/claw-import && sudo cp -a ~/claw-import/claw-nightly-<ts> /home/sebastian/claw-import/ && sudo chown -R sebastian:sebastian /home/sebastian/claw-import && rm -rf ~/claw-import'
CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- bash /opt/vm-claw/migrate/import.sh drill /home/sebastian/claw-import/claw-nightly-<ts>
CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- bash /opt/vm-claw/tests/acceptance.sh rehearsal <lan-router-ip>
CLAW_INSTANCE=claw-drill host/claw.sh destroy
```

The admin-side copy goes through `~/claw-import` because admin cannot write into the bot's home; `limactl copy` into an existing directory nests the copy in it (`docs/verification.md`). Delete the dev Mac's copy of the nightly afterwards: it holds live secrets. In `rehearsal` the guard replay must report WhatsApp unlinked ("Move the bot to its own account"): a drill that reports it linked failed. A bare `host/claw.sh destroy` force-deletes the default instance `claw`: always name the drill's instance.

### Rehearse the move

Before the production switch, `rehome.sh` is rehearsed on a scratch instance that is set up the old way, with the bot as admin. Steps 2 to 10 run on the dev Mac, never the appliance; only step 1 touches the host, and only to read the restic repository. Never `switch final` or `import.sh final` on a drill: that would put a second gateway on the production WhatsApp credentials. Every command names `CLAW_INSTANCE=claw-drill` itself. Record each result as you go (step 11).

1. Get the newest night to the dev Mac through restic (the host writes a scratch restore directory, `~/vm-claw-restore.*`, and you remove it at the end of this step), which also proves "Restore from restic". On the host (over `ssh -t`; if the keychain is locked, the owner unlocks it there first):

   ```bash
   export PATH=/opt/homebrew/bin:$PATH
   export RESTIC_REPOSITORY="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups/vm-claw-restic"
   export RESTIC_PASSWORD_COMMAND="security find-generic-password -s vm-claw-restic -w"
   restic snapshots --tag vm-claw | tail -4        # one snapshot per night
   d=$(mktemp -d "$HOME/vm-claw-restore.XXXXXX"); chmod 700 "$d"
   restic restore latest --tag vm-claw --target "$d"
   night=$(find "$d" -type d -name 'claw-nightly-*Z' | sort | tail -1); echo "NIGHT=$night"
   (cd "$night" && grep -v '^mode=' MANIFEST | shasum -a 256 --strict -c -)
   ```

   Both archives must read `OK` (`openclaw-backup.tar.gz: OK`, `filestate.tar.gz: OK`). Then, on the dev Mac: `mkdir -m 700 -p <drill-input> && scp -rp <host>:"<the NIGHT path>" <drill-input>/`, and on the host `rm -rf ~/vm-claw-restore.*`.
2. A fresh drill, provisioned, with its stack check (expect `provision: changed=N ok=M` without `FAILED`, then `stack: OK` and a skipped Tailscale-operator line):

   ```bash
   CLAW_INSTANCE=claw-drill host/claw.sh destroy 2>/dev/null || true
   CLAW_INSTANCE=claw-drill host/claw.sh create --memory 8 && CLAW_INSTANCE=claw-drill host/claw.sh start && CLAW_INSTANCE=claw-drill host/claw.sh provision
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/tests/stack-check.sh
   ```

3. Production the old way, as admin: provisioning no longer gives admin linger and a drill import installs no nightly, so both are added by hand. The import ends with `import: done (drill). Now run tests/acceptance.sh rehearsal <lan-ip>` and, as it is the same home, prints no rewrite line.

   ```bash
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- sudo loginctl enable-linger admin
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- mkdir -p -m 700 claw-import
   limactl copy --backend=scp -r <drill-input>/claw-nightly-<ts> claw-drill:claw-import/
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/migrate/import.sh drill /Users/admin/claw-import/claw-nightly-<ts>
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash -c 'install -d ~/ops/backup ~/ops/lib ~/.config/systemd/user && cp /opt/vm-claw/ops/backup/nightly-backup.sh /opt/vm-claw/ops/backup/backup-health.mjs ~/ops/backup/ && cp /opt/vm-claw/ops/lib/dotenv-token.sh ~/ops/lib/ && cp /opt/vm-claw/ops/backup/openclaw-nightly-backup.service /opt/vm-claw/ops/backup/openclaw-nightly-backup.timer ~/.config/systemd/user/ && systemctl --user daemon-reload && systemctl --user enable --now openclaw-nightly-backup.timer'
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- systemctl --user is-active openclaw-gateway.service openclaw-listener-guard.timer openclaw-nightly-backup.timer   # active, three times
   ```

4. A baseline as admin, with the gateway stopped (doctor writes), and two counts to compare later:

   ```bash
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash -c 'systemctl --user stop openclaw-listener-guard.timer openclaw-gateway.service; openclaw doctor --non-interactive --allow-exec > ~/doctor-before.txt 2>&1; systemctl --user start openclaw-gateway.service openclaw-listener-guard.timer'
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash -c 'openclaw sessions --all-agents --json | jq ".sessions | length"; for i in $(seq 12); do t=$(openclaw cron list --all --json 2>/dev/null | jq -r ".total // empty"); [ -n "$t" ] && break; sleep 5; done; echo "${t:-unreadable}"'   # automations live in SQLite; the count reads null until the gateway is up
   ```

5. The switch, in drill mode. Expect `prepare: OK`, the stop and import lines, `switch: done (drill, …)`, every acceptance item `PASS`, the two `MANUAL` lines and `verify: PASS`. If the leftover scan names files, stop and record the list: the fix is a separate, owner-approved change (make the reference home-relative at its source, or extend `migrate/homepaths.mjs`), then rehearse again from step 1.

   ```bash
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh prepare
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh switch drill
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh verify rehearsal <lan-router-ip>
   ```

5a. Prove the host pull as the bot (the one path the drill otherwise never runs: a binary tar stream from the guest, over `limactl shell`, as `sudo -n -u sebastian`). On the host or dev Mac, with a **scratch** destination and a **scratch** restic repository: `pull-backups.sh` honours `CLAW_BACKUP_DEST`, `RESTIC_REPOSITORY` and `RESTIC_PASSWORD` (or `RESTIC_PASSWORD_COMMAND`), and with `RESTIC_REPOSITORY` set it neither looks at iCloud Drive nor touches the keychain password, so nothing here reaches `~/Backups/vm-claw` or the iCloud repository. Expect the pull to print no failure, the night in the scratch destination with its three files, and exactly one snapshot tagged `vm-claw`. On the dev Mac `restic` must be installed (`brew install restic`); without it the pull streams and gates the night, then stops at the snapshot. Then delete both scratch directories (they hold live secrets):

   ```bash
   CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- bash /opt/vm-claw/ops/backup/nightly-backup.sh         # a drill installs no backup units (import.sh, final only)
   CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- ls backups                                              # a claw-nightly-<ts>, no .partial
   scratch=$(mktemp -d "${TMPDIR:-/tmp}/pull-drill.XXXXXX")
   CLAW_INSTANCE=claw-drill CLAW_BACKUP_DEST="$scratch/dest" RESTIC_REPOSITORY="$scratch/restic" RESTIC_PASSWORD=scratch-drill-only bash host/pull-backups.sh
   ls "$scratch/dest"                                                                                         # the night, with MANIFEST and both archives
   CLAW_INSTANCE=claw-drill RESTIC_REPOSITORY="$scratch/restic" RESTIC_PASSWORD=scratch-drill-only restic snapshots --tag vm-claw
   rm -rf "$scratch"
   ```

   The gate (MANIFEST hashes) ran inside the pull: a night that failed it is dropped and named, so a night present in `$scratch/dest` passed. To see the stream alone, in a fresh scratch directory: `s=$(mktemp -d "${TMPDIR:-/tmp}/pull-stream.XXXXXX")`, then `limactl shell --workdir / claw-drill -- sudo -n -u sebastian -- tar -C /home/sebastian/backups -cf - <night> | tar -xf - -C "$s"`, then `(cd "$s/<night>" && grep -v '^mode=' MANIFEST | shasum -a 256 --strict --quiet -c -)` (prints nothing and exits 0 when the hashes match), then `rm -rf "$s"` (it holds live secrets).

6. Hand checks as the bot. Expect: `uid=2000(sebastian) gid=2000(sebastian) groups=2000(sebastian)`; `sudo: a password is required`, `rc=1`; `Operation not permitted`, `rc=1`; every listed process owned by `sebastian`; `sebastian 7..` for `/tmp/openclaw`; the per-user journal readable; memory paths under `/home/sebastian` and search results; from the labelled counts: `sessions:` equal to step 4's first number, `session list naming /Users/admin:` recorded, whatever it is, `automations:` equal to step 4's second number, and `:0` for both files; WhatsApp not linked (stripped) and no iMessage; the wacli store opens with its message count.

   ```bash
   CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- id
   CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- sudo -n true; echo "rc=$?"
   CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- /usr/sbin/nft list ruleset; echo "rc=$?"
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash -c 'ps -eo user:12=,args= | grep -E "openclaw|guard\.mjs|nightly-backup|wacli" | grep -v grep'
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- sudo stat -c '%U %a' /tmp/openclaw   # sebastian 7..
   CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- journalctl --user -u openclaw-gateway.service -n 5 --no-pager
   CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- openclaw memory status --agent main
   CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- openclaw memory search <a word from a recent note> --agent main
   CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- bash -c 'echo "sessions: $(openclaw sessions --all-agents --json | jq ".sessions | length")"; echo "session list naming /Users/admin: $(openclaw sessions --all-agents --json | grep -c /Users/admin || true)"; echo "automations: $(openclaw cron list --all --json | jq .total)"; grep -c /Users/admin .openclaw/openclaw.json || true'
   CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- openclaw channels status
   CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- wacli doctor --read-only --json
   ```

7. Doctor after the switch, against the baseline (the bot's gateway stopped). Expect no line only on the right (no new warning); record the diff:

   ```bash
   CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- bash -c 'systemctl --user stop openclaw-listener-guard.timer openclaw-gateway.service; openclaw doctor --non-interactive --allow-exec > ~/doctor-after.txt 2>&1; systemctl --user start openclaw-gateway.service openclaw-listener-guard.timer'
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash -c 'diff <(grep -iE "warn|error|fail" ~/doctor-before.txt | sed "s#/Users/admin#~#g") <(sudo cat /home/sebastian/doctor-after.txt | grep -iE "warn|error|fail" | sed "s#/home/sebastian#~#g")'
   ```

8. Rollback before `retire`, then the switch again and `retire`. Expect `rollback: done; admin's gateway is active`, then `active` for admin and `inactive` for the bot; the switch and verify pass again; `retire` ends with `retire: admin's copy is in …`; the retired dir is `root 700`; admin's home lists none of `.openclaw brain .wacli ops backups claw-import`; `Linger=no`:

   ```bash
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh rollback
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- systemctl --user is-active openclaw-gateway.service
   CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- systemctl --user is-active openclaw-gateway.service
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh switch drill
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh verify rehearsal <lan-router-ip>
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh retire
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash -c 'sudo stat -c "%U %a" /var/lib/claw-retired-admin-*; ls -A ~; loginctl show-user admin -p Linger'
   ```

9. Rollback after `retire`, then switch, verify and `retire` once more. Expect `rehome: admin's copy is back from /var/lib/claw-retired-admin-<date>`, `rollback: done`, `active`, then the same passes as step 8:

   ```bash
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh rollback
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- systemctl --user is-active openclaw-gateway.service
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh switch drill
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh verify rehearsal <lan-router-ip>
   CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh retire
   ```

10. Reboot once: the bot's units must start without a login. Expect no `sebastian` session in the list (check it first: every `host/claw.sh sebastian --` opens one through `sudo`), then `active` twice, and the gateway's `ActiveEnterTimestamp` after the boot time from `uptime -s`:

    ```bash
    CLAW_INSTANCE=claw-drill host/claw.sh stop
    CLAW_INSTANCE=claw-drill host/claw.sh start
    CLAW_INSTANCE=claw-drill host/claw.sh shell -- bash -c 'uptime -s; loginctl list-sessions --no-legend'
    CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- systemctl --user is-active openclaw-gateway.service openclaw-listener-guard.timer
    CLAW_INSTANCE=claw-drill host/claw.sh sebastian -- systemctl --user show openclaw-gateway.service -p ActiveEnterTimestamp
    ```

11. Record the results in `docs/verification.md` (one row per step, the counts from steps 4 and 6, the doctor diff, any deviation), then `CLAW_INSTANCE=claw-drill host/claw.sh destroy` and delete `<drill-input>` on the dev Mac: it holds live secrets.


## Rebuild

For a Debian major or a broken guest. Before the switch, follow the earlier checkout's README instead of this section; after a rollback of the switch, use `host/claw.sh shell --` in place of `host/claw.sh sebastian --` below. The real path is a nightly taken with the gateway stopped, imported with `import.sh final` into a new instance. Lima cannot rename an instance, so the new one keeps its own name.

1. Stop the old guest's bot, and prove it stopped:

   ```bash
   host/claw.sh sebastian -- systemctl --user disable --now openclaw-listener-guard.timer openclaw-listener-guard.service openclaw-nightly-backup.timer openclaw-gateway.service
   host/claw.sh sebastian -- systemctl --user is-active openclaw-gateway.service openclaw-listener-guard.service   # both: inactive or failed
   host/claw.sh shell -- bash -c 'ps -eo user:12=,args= | grep -E "openclaw|guard\.mjs" | grep -v grep'   # must print nothing
   ```

   `is-active` prints `inactive` for a unit the account does not have, so the `ps` line is the real proof: it must print nothing, whichever user a gateway ran as.
2. Take a nightly with the gateway stopped and pull it to the host: `host/claw.sh sebastian -- systemctl --user start openclaw-nightly-backup.service`, then `bash host/pull-backups.sh`.
3. To keep the old node's name free, rename it now, on the old instance, before `CLAW_INSTANCE` is exported for the new one: `host/claw.sh shell -- sudo tailscale set --hostname=<name>-old`. Then keep the old instance as the rollback: `limactl autostart disable claw; limactl stop claw`. It holds the WhatsApp credentials and must not start again while the new one runs. Or delete it (`host/claw.sh destroy`) and keep only the backups.
4. Build the new instance: `export CLAW_INSTANCE=claw-<new>`, then the "Build" commands (`create --memory 8`, `start`, `provision`, `stack-check.sh`, `isolation-check.sh`, `firewall-check.sh`).
5. Tailscale: remove the old node in the Tailscale admin console (or do the rename in step 3), then join the new one as `<name>` ("Build") and run `host/claw.sh provision` again for the operator.
6. Copy the nightly into the bot's `~/claw-import` the way "Rehearse" does, then `host/claw.sh sebastian -- bash /opt/vm-claw/migrate/import.sh final /home/sebastian/claw-import/claw-nightly-<ts>`.
7. `host/claw.sh sebastian -- bash /opt/vm-claw/tests/acceptance.sh final <lan-router-ip>`; the owner confirms the `MANUAL` lines.
8. On the host: `limactl autostart enable "$CLAW_INSTANCE"`, and `CLAW_INSTANCE=claw-<new> bash host/install.sh` over `ssh -t`, so the pull agent pulls from the new instance. From then on put `CLAW_INSTANCE=claw-<new>` in front of every host script.

## Restore from restic

When the host disk is lost, the restic repository in iCloud Drive is the only copy that survives. Its password is in the owner's Private 1Password vault (the value `host/install.sh` stores in the login keychain as `vm-claw-restic`). On a new or rebuilt host with the repo cloned, iCloud Drive on and `bash host/install.sh` run:

```bash
export RESTIC_REPOSITORY="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Backups/vm-claw-restic"
export RESTIC_PASSWORD_COMMAND="security find-generic-password -s vm-claw-restic -w"
restic snapshots --tag vm-claw                                   # one snapshot per night
mkdir -m 700 ~/vm-claw-restore
restic restore latest --tag vm-claw --target ~/vm-claw-restore
night=$(find ~/vm-claw-restore -type d -name 'claw-nightly-*Z' | sort | tail -1)
(cd "$night" && grep -v '^mode=' MANIFEST | shasum -a 256 --strict -c -)
```

The restore recreates the snapshot's absolute path under the target. With the checksums OK, follow "Rebuild" from step 4 with `$night` as the host-side night, then delete `~/vm-claw-restore`: it holds live secrets.

## Rollback

### Of the move to the bot account (until the retired copy is deleted)

On production the retired copy was deleted on 2026-10-16, so `rollback` has nothing to roll back to there: restore from a backup instead ("Restore"). The steps below hold for a guest that still has admin's state or a retired copy.

```bash
host/claw.sh shell -- bash /opt/vm-claw/migrate/rehome.sh rollback
```

It takes the phase lock first, so no other rehome phase runs beside it (`/run/lock/claw-rehome.lock`). It needs admin's own state or exactly one retired copy (`/var/lib/claw-retired-admin-*`); with neither, or with several, it refuses. Then, in this order:

1. A read-only preflight, before anything is stopped. If `retire` ran, it needs a readable `RETIRED` in the retired copy, and it names every collision in admin's home (items and unit files that exist there already) and every item missing from the retired copy. On any problem it refuses with nothing stopped or moved. If `RETIRED` is missing, a retire died half-way: see "A half-done retire" below.
2. It stops and proves down the bot's gateway, guard and nightly timer and service, then admin's own units. From here on no gateway runs.
3. If `retire` ran, it moves admin's copy back from `/var/lib/claw-retired-admin-<date>/` and removes the emptied directory.
4. It always turns admin's linger back on (a retire that died after turning it off, or a restore by hand, must not leave admin without it).
5. WhatsApp state, by family. The bot's gateway ran since the switch, so its state is newer than admin's. For each family the bot actually has, admin's own set of that family moves aside to `~/.claw-rollback-aside-<ts>/` and the bot's set is copied over, as admin's: `.openclaw/credentials/whatsapp*`, and separately `.wacli/session.db*` with its `-wal` and `-shm`. A family the bot lacks stays admin's own, untouched (moving it aside with nothing to replace it would unpair it).
6. It sets the bot's copy (its state directories and its `openclaw-*` unit files) aside in `/home/sebastian/rehome-rolled-back-<ts>/`, so nothing starts on it and a later switch starts clean. The bot's gateway logs (`/tmp/openclaw`) go aside separately, to `/tmp/openclaw.rolled-back-<ts>`.
7. It re-proves the bot's gateway is down right before admin's units are enabled, and refuses if not.
8. It enables admin's gateway, guard and nightly timer and waits up to 30 s for admin's gateway to be active. Then it clears the `switched`, `imported`, `verified` and `retired` records and writes `rolled-back-<ts>`.

Then check `openclaw channels status` as admin: WhatsApp linked, running, connected. Messages and sessions created only under the bot stay in the aside copy. The host pull reads the bot's backups, so after a rollback unload it (`launchctl bootout gui/$(id -u)/local.vm-claw.pull-backups`) until the switch is repeated; the 09:00 backup check then reports the stale host stamp after 30 h, as expected.

#### Several retired copies

`rollback` refuses when `/var/lib/claw-retired-admin-*` holds more than one directory ("restore one by hand"). First see what each holds: `host/claw.sh shell -- sudo bash -c 'for d in /var/lib/claw-retired-admin-*; do ls "$d"/RETIRED "$d"/RETIRING 2>/dev/null; done'`. A directory with `RETIRED` is a complete retire; one with only `RETIRING` is a half-done one ("A half-done retire"; `*.restored-by-hand` entries are not counted).

Do not recover the half-done copy alone and then roll back from the other: a half-done retire moves `.openclaw` first, so `rollback` would find it back in admin's home and refuse. Move the items of both copies back by hand, then set both aside:

1. For the complete copy, run the move-back command of "A half-done retire" with `f=RETIRED`; for the half-done copy, with `f=RETIRING`.
2. `sudo mv <dir> <dir>.restored-by-hand` for both directories (and for any further one that holds nothing of use).
3. Run `rehome.sh rollback`: with no retired copy left it rolls back from admin's own home. The directories set aside stay until the owner decides ("Retire").

#### A half-done retire

A retire that died half-way leaves `RETIRING` and no `RETIRED` in `/var/lib/claw-retired-admin-<date>/`, and `rollback` then refuses with: `no readable <dir>/RETIRED: nothing was stopped. If <dir>/RETIRING exists, a retire died half-way: …`. `RETIRING` lists what that retire meant to move (its first line is a header, the rest are paths relative to admin's home). The listed items that are present under `<dir>/home` are the ones that moved. To see which items moved (use `RETIRED` in place of `RETIRING` for a complete copy): `host/claw.sh shell -- sudo bash -c 'cd <dir> && sed -n "2,\$p" RETIRING | while IFS= read -r i; do if [ -e "home/$i" ] || [ -L "home/$i" ]; then echo "$i"; fi; done'`. Both recoveries start the same way, as admin:

1. Move each of those items back to the same path under admin's home, and the unit files in `<dir>/units` to `~/.config/systemd/user`. As in the code's own restore (`rehome.sh rollback`), root only does the `mv`, which keeps admin as the owner, so no `chown` is needed. Set `f=RETIRING` (a half-done copy: items present under `<dir>/home` move, absent ones are skipped) or `f=RETIRED` (a complete copy):

   ```bash
   host/claw.sh shell -- bash -c 'd=<dir>; f=RETIRING; sudo sed -n "2,\$p" "$d/$f" | while IFS= read -r i; do if sudo test -e "$d/home/$i" || sudo test -L "$d/home/$i"; then mkdir -p "$(dirname "$HOME/$i")" && sudo mv "$d/home/$i" "$HOME/$i"; fi; done; for u in $(sudo ls -A "$d/units"); do mkdir -p ~/.config/systemd/user && sudo mv "$d/units/$u" ~/.config/systemd/user/; done'
   ```

2. Move the emptied directory aside: `sudo mv <dir> <dir>.restored-by-hand` (`rollback` ignores a directory with that suffix, and `retire` only refuses an existing destination).

Then choose:

- (a) Finish the retire, when the switch itself is verified and you only want admin's copy retired: run `rehome.sh retire` again. It needs the `verified` record (still there) and the bot's gateway active; it takes a fresh dated directory, with no downtime. The `.restored-by-hand` directory is not empty by then: it still holds `RETIRING` and empty subdirectories. It goes with the owner's cleanup ("Retire").
- (b) Go back to admin: run `rehome.sh rollback`. With no retired copy it rolls back from admin's own home.

## Retire

Fourteen days after `rehome.sh retire`, with no rollback. The retired copy holds what `retire` moved out of admin's home: the bot's directories, every `~/.ssh` entry except `authorized_keys`, the timer stamps, admin's bot unit files (`<dir>/units`) and the earlier imports' aside dirs (`.openclaw.pre-import-*`, `.openclaw-stale-*`, `openclaw-agents-retired-*`). Look first. A `*.restored-by-hand` entry is expected after a rollback or recovery and is not the copy to check; stop if any other directory than the one you mean shows:

```bash
host/claw.sh shell -- sudo ls -d /var/lib/claw-retired-admin-*
host/claw.sh shell -- sudo head -1 /var/lib/claw-retired-admin-<date>/RETIRED      # its two dates: the retire day, then 'delete after'
host/claw.sh sebastian -- bash /opt/vm-claw/tests/acceptance.sh final <lan-router-ip>
```

Stop here unless all three hold: the "delete after" date on the first line of `RETIRED` (the second date, not the retire day) is today or earlier; acceptance ends with its line `acceptance (final): automated items PASS`; and the owner has confirmed that no rollback is wanted. The delete cannot be undone. Only then:

```bash
host/claw.sh shell -- sudo rm -rf /var/lib/claw-retired-admin-<date>
host/claw.sh sebastian -- rm -rf claw-import
```

Plan Task 12 also removes `~/vm-claw` (admin's old checkout). After that `rehome.sh rollback` has nothing to roll back to; restore from a backup instead.

Whether to also delete the leftovers of a rollback or a hand restore is the owner's decision: ask whether anything in them is still needed first. They are `/var/lib/claw-retired-admin-<date>.restored-by-hand` (a retired directory moved aside by hand, see "A half-done retire"), `~/.claw-rollback-aside-<ts>/` in admin's home (admin's own WhatsApp files from before a rollback) and `/home/sebastian/rehome-rolled-back-<ts>/` (the bot's copy from before a rollback). They hold credentials, tokens and several GB. Once the owner has confirmed, remove them: `host/claw.sh shell -- sudo bash -c 'rm -rf /var/lib/claw-retired-admin-*.restored-by-hand /home/sebastian/rehome-rolled-back-*'` and `host/claw.sh shell -- bash -c 'rm -rf ~/.claw-rollback-aside-*'`.

## License

MIT
