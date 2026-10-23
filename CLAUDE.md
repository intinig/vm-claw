# CLAUDE.md

Guidance for Claude Code (claude.ai/code) in this repository. The runbook is `README.md`; the designs are `docs/superpowers/specs/2026-09-30-linux-vm-migration-design.md` and its addendum `docs/superpowers/specs/2026-10-02-bot-user-sebastian-design.md`; verified facts are in `docs/verification.md`.

## Project

Shell and Node tooling that builds and operates a security-isolated Lima VM (`claw`, Debian 13 arm64, `vz`) running an OpenClaw gateway on a Mac mini host. It replaced a Tart macOS VM on 2026-10-01. The target layout: the bot runs as the unprivileged account `sebastian` once the production switch (`migrate/rehome.sh`) has run; until then, and after a rollback of it, it runs as `admin`, which stays Lima's login and maintenance user. Check which before using `host/claw.sh sebastian --` (README intro).

## Commands

```bash
make lint                        # shellcheck on every .sh
make unit                        # node --test plus the bash suites (import, home-roots, rehome, backup, install, claw, acceptance, stack-check, lib, vercmp)
make test                        # lint + unit + unit-bash32
host/claw.sh create|deploy|provision|start|stop|shell|destroy
host/claw.sh sebastian -- <cmd>  # a command as the bot, with its user-session environment
CLAW_INSTANCE=<name> host/...    # another instance (a drill, a rebuild); the default is claw
host/install.sh                  # host: Lima, restic, backup pull agent (run over ssh -t)
tests/isolation-check.sh         # host side
```

Run the bash suites under `/bin/bash` 3.2 too (macOS default), the scripts included: `PATH="/bin:$PATH" /bin/bash <suite>`. No `mapfile`, no associative arrays.

## Global constraints

- The repo is public: never commit secrets, IPs, phone numbers, WhatsApp JIDs, account names, job IDs, tailnet names or key fragments. Never commit identifiers. Scripts find things by pattern, not by hard-coded identifier; docs use placeholders such as `<host>`, `<lan-router-ip>`, `<owner-number>`, `<name>`.
- Two accounts in the guest, from the switch on. `admin` (home `/Users/admin`, passwordless sudo) is Lima's login and maintenance user and owns no bot data or units. The bot is `sebastian`: UID and GID 2000, home `/home/sebastian` at mode 700, password locked, its own group only, no sudo, no SSH login (`DenyUsers sebastian`, no `authorized_keys`), linger, Tailscale operator. Its name, ids and home live only in `provision/bot.sh`; scripts that run as the bot use `$HOME`.
- The guest's repo is `/opt/vm-claw`: root-owned, read-only for everyone else, put there only by `host/claw.sh deploy` (a `git archive` of HEAD). Never stage anything root will run in a directory the bot can write, such as `/tmp`.
- Look inside the bot's home only through `sudo` or as the bot: as admin, a test on a mode-700 directory fails for want of permission and reads as "absent".
- Guest timezone `UTC`.
- Pinned versions (`provision/versions.env`): OpenClaw `2026.10.2` (a floor: provisioning never downgrades), node major `24`, wacli `0.13.0`, sag `0.4.0`. OpenClaw upgrades are a maintenance action as admin (README "Upgrades"): the bot cannot write the global npm install.
- Isolation: `mounts: []`; exactly one port forward (guest `127.0.0.1:18789` to host `127.0.0.1:18789`); NAT only; guest egress to RFC1918/link-local dropped except DNS and DHCP to Lima's gateway. Only root can change the `inet claw` table, and the bot is not root; `tests/acceptance.sh` passes that item only on a real "Operation not permitted" denial.
- Never run two gateways with the same WhatsApp credentials. Rehearsal and drill imports exclude them and disable cron. `migrate/rehome.sh` proves admin's gateway down before the bot's starts, and the bot's down before admin's restarts. Its phases take the lock `/run/lock/claw-rehome.lock` and record progress in `/var/lib/claw-rehome/`. Acceptance in `rehearsal` mode requires the guard replay to report WhatsApp unlinked (`skip: WhatsApp not linked`); `final` requires `restart:`.
- `import.sh final` refuses `mode=rehearsal`, accepts `mode=nightly` as final; `rehearsal` refuses an archive with WhatsApp credentials; `drill` strips them. From another home it rewrites that home in live configuration, fails on anything left over, and installs no `authorized_keys`; it refuses a symlinked `~/.ssh` and, cross-home, takes only `ocsb_vault`, `ocsb_vault.pub`, `config` and `known_hosts` into `.ssh`. Do not loosen these.
- Never run git inside the guest (a worktree's `.git` file does not resolve there). Run `openclaw doctor --non-interactive` only with the gateway stopped: it writes.
- Never touch the live guest, the old VM, the appliance or a gateway from a docs or code task.
- OpenClaw posture (carried over from the Tart era, still true of the live config): the gateway binds to loopback and is reachable from the tailnet only through Tailscale Serve; token auth stays on; WhatsApp DM and group policies are allowlists, never `open`; plugins are added by exact name, never by wildcard or auto-install.

## Architecture

- `lima/claw.yaml`, `provision/`: VM definition and idempotent guest provisioning (root); `provision/bot.sh` names the bot account.
- `host/`: `claw.sh` wrapper (`deploy`, `sebastian -- <cmd>`, `CLAW_INSTANCE`), `install.sh`, `pull-backups.sh` (streams the bot's nights through `sudo -n -u sebastian`) and its launchd plist.
- `migrate/`: `export.sh` (old VM), `import.sh` (guest, as the bot), the binary-path and home-path rewrites, the free-text scan, and `rehome.sh` (the in-place move to the bot account).
- `ops/`: listener guard (with its replay fixture), nightly backup, `backup-health.mjs`, shared dotenv-token parser, the browser's display (Xvfb user unit plus a drop-in giving the gateway `DISPLAY`: headless Chromium is blocked by Cloudflare).
- `tests/`: isolation, firewall, stack (as admin) and acceptance (as the bot) checks.

## Rollback

- Of the move to the bot account: `migrate/rehome.sh rollback`, until the retired copy is deleted (README "Rollback", which also covers a retire that died half-way). On production it was deleted on 2026-10-16: restore from a backup instead (README "Restore").
- The Tart VM was deleted on 2026-10-16; there is no rollback to it.
