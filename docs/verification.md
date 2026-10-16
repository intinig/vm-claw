# Verified facts (2026-09-30)

| Fact | Result | Consequence |
|---|---|---|
| wacli 0.13.0 linux-arm64 release | yes (`wacli_0.13.0_linux_arm64.tar.gz`; SHA-256 matches the published `checksums.txt`) | install the release tarball |
| sag linux-arm64 release | no at 0.3.0 (assets are darwin_universal, linux_amd64 and windows_amd64 only); 0.4.0 is the earliest release that ships `sag_0.4.0_linux_arm64.tar.gz` (SHA-256 matches the published `.sha256` file) | pinned to 0.4.0, one minor step above the Tart guest's 0.3.0, and installed from the release tarball. The no-upgrade rule protects stateful tools (the wacli store); sag is a stateless TTS CLI, so the smallest version step that avoids a Go and cgo toolchain in provisioning is the safer choice |
| summarize distribution | npm package `@steipete/summarize` (the Homebrew formula is a wrapper that installs it from the npm registry and depends on node, ffmpeg, tesseract and yt-dlp); the Tart guest has 0.21.6 | installed on the Linux guest from the npm package named by `SUMMARIZE_SPEC` (`@steipete/summarize@0.21.6`) |
| backup restore layout | `TARGET/ARCHIVE_ROOT/payload/posix/Users/admin/.openclaw`, where `TARGET` is the `--target` directory and `ARCHIVE_ROOT` is the archive's timestamped top-level directory (`TIMESTAMP-openclaw-backup`; also reported as `archiveRoot` in the `--json` output) | import.sh copies from there (resolve `ARCHIVE_ROOT` by globbing the single directory under `TARGET`; the plan's `payload/posix/...` path is missing this level) |
| cron scheduler disable key | `cron.enabled` (boolean, "Automations Enabled": pauses all automation execution without deleting jobs) | rehearsal disables via the key |
| `openclaw config unset` | yes (`openclaw config unset PATH`, removes a value by dot path; `openclaw config patch` also deletes a path when given null) | iMessage channel removed via unset |
| Host RAM / Tart VM RAM | 16 GB / 8 GiB | rehearsal on dev Mac; host pre-provisions at 4 GiB |
| Lima version | 2.2.0 | `limactl autostart` (start-at-login deprecated) |
| `openclaw gateway install` on Linux (guest, OpenClaw 2026.9.7) | creates the systemd user unit `openclaw-gateway.service` in `~/.config/systemd/user/`, enables it and starts it at once; it writes no `service-env/*.env`. The unit gets `EnvironmentFile=-~/.openclaw/gateway.systemd.env` (systemd `KEY=value` lines, mode 600) only when OpenClaw has values to put there; a hand-written file with an unrelated key was kept and wired in, but a later reinstall emptied it of `OP_SERVICE_ACCOUNT_TOKEN` (tested with a stand-in exec SecretRef provider that listed the variable in `passEnv`). `~/.openclaw/.env` (OpenClaw's documented global env file, mode 600) carried the token for both the service and the CLI, and survived reinstall and `doctor --fix`; with the stand-in provider failing whenever the variable was missing, the gateway exited and the CLI failed without that file. `openclaw gateway uninstall` removes the unit but leaves `gateway.systemd.env` and the state | import.sh writes the bootstrap token to `~/.openclaw/.env` before install; no guard drop-in is needed because the unit name is the guard's default |
| `gateway install` starts the unit, `doctor --fix` needs the state offline | a gateway running while `doctor --fix` does its state maintenance exits with "undergoing offline maintenance", restarts ten times in under a minute and trips the start limit (`enable --now` then fails) | import.sh stops the unit after install, runs doctor, then `reset-failed` and `enable --now` |
| Tailscale Serve in the migrated config (`gateway.tailscale.mode` = `serve`/`funnel`) | OpenClaw holds Serve/Funnel as a foreground Tailscale claim and the gateway starts only once it is active: serve mode requires a logged-in tailscale; startup fails "Logged out" otherwise (seen in the rehearsal: restart loop, then the breaker tripped) | import.sh sets the mode to `off` for rehearsal and drill (never publish on the tailnet); a final import requires `tailscale status --json` `BackendState` = `Running` before the first write |
| The old VM's `~/ops` | carries the macOS listener guard (`ops/listener-guard/listener-guard.mjs`, run by launchd) and its `launchd.out.log` / `launchd.err.log`; the free-text scan flags it (`launchctl`). The rest of `~/ops` is benchmark scripts, which the scan accepts | import.sh retires exactly those three files (all modes, one log line each, no allow-list entry); they stay in the export archive and the safety copies |
| `openclaw config unset` on an absent path | exits 1 with `Config path not found` | import.sh tolerates exactly that message (a backup with no iMessage) and fails on anything else |
| Checksum tools in the guest | both `sha256sum` and `shasum` are installed; on macOS `shasum -a 256` writes the MANIFEST and `sha256sum -c` reads it | import.sh verifies with `sha256sum -c` when present, else `shasum -a 256 -c` |
| Guest `/tmp` | 3.9 GB tmpfs (RAM-backed; Debian 13 default), against a multi-GB state | import.sh stages the restore under `$HOME`, never `/tmp`; copy exports to the guest under `$HOME` too |
| Gateway log path on Linux | `/tmp/openclaw/openclaw-<date>.log`, the listener guard's `GUARD_LOG_DIR`; the unit has no `PrivateTmp` | the guard unit's log path is right |
| `automations list --all --json` shape | `{ jobs: [...] }`, each job with `payload.kind` (`command`, `agentTurn`, `heartbeat`) and, for commands, `payload.argv`; `--command <shell>` stores `argv: ["sh", "-lc", <shell>]` | the argv rewrite finds jobs by `argv[0]` under `/opt/homebrew`; shell-string jobs keep the old path in the string and rely on the compat links |
| `openclaw backup create` and `~/.openclaw/.env` (OpenClaw 2026.9.7, guest) | it is archived: `payload/posix<home>/.openclaw/.env` is in `openclaw-backup.tar.gz` along with `credentials/whatsapp*`. `--verify` passes | both archives of a nightly carry the bootstrap token in plaintext: the backup dir is mode 700 with 600 files, and the off-site copy goes into an encrypted restic repository. The nightly still puts `.openclaw/.env` into `filestate.tar.gz`, because `import.sh` reads the token from there |
| `openclaw backup create --verify` needs the bootstrap token? | no: it succeeded with `~/.openclaw/.env` moved away, and under a bare `systemd --user` oneshot (no `EnvironmentFile`, default PATH finds `/usr/bin/openclaw`); the stand-in exec SecretRef provider fails without the token, so nothing it guards was resolved | the nightly sources no env file (the brief's `service-env/*.env` is a macOS artefact that does not exist on Linux); it only checks that `.env` exists and yields a token through the shared parser (`ops/lib/dotenv-token.sh`), because a backup whose token `import.sh` would refuse cannot be restored |
| `limactl copy -r claw:DIR DEST` (Lima 2.2.0, guest has rsync) | DEST absent: DEST becomes a copy of DIR with modes kept (dir 700, files 600), with either backend. DEST present: `--backend=rsync` merges DIR's contents into it (stale files stay), `--backend=scp` nests the copy as `DEST/<basename of DIR>`. `auto` takes whichever `rsync` comes first on PATH: Homebrew's 3.5.0 in an interactive shell on the dev Mac, while `/usr/bin/rsync` is openrsync (protocol 29) and launchd's PATH has no Homebrew (inferred: not run under launchd) | `pull-backups.sh` originally passed `--backend=scp` explicitly, so the result did not depend on PATH. Since the switch the backups are the bot's in a mode-700 home, which admin's `limactl copy` cannot read, so the pull streams each night with `sudo -n -u sebastian -- tar -cf -` through `limactl shell` into a fresh `<name>.partial`, removing any stale one first; it verifies the copy and renames it only then. `limactl copy` is still what the rehearsal and rebuild steps use to put a night into the guest |
| macOS `date -j -u -f %Y%m%dT%H%M%SZ` on a nightly's name timestamp | parses it (`20200101T000000Z` gives `1577836800`) | `pull-backups.sh` judges the age of the newest guest nightly from its name |
| Nightly units on the guest | `systemd-analyze --user verify` accepts the service and the timer; `OnCalendar=*-*-* 03:30:00 UTC` normalizes unchanged (next elapse 03:30 UTC); `systemctl --user start openclaw-nightly-backup.service` ran to `Result=success` | the units are installed as written in `ops/backup/` |
| A guest nightly restores with `import.sh drill` | yes (synthetic state: dummy WhatsApp credentials, a wacli session, a stand-in exec SecretRef provider): rc 0 in 75 s; both WhatsApp credential sets and the session stripped, `cron.enabled=false`, the token parsed from the filestate `.openclaw/.env`, gateway and guard timer up, `secrets audit --check` clean | the nightly layout is what `import.sh` restores; Task 12 still has to let `final` mode accept `mode=nightly` |
| `openclaw secrets audit --allow-exec` (OpenClaw 2026.9.7, guest with no state) | exit 0 and one summary line, `Secrets audit: clean. plaintext=0, unresolved=0, shadowed=0, storeResidue=0, legacy=0.`; findings add up to 20 `- [CODE] file:path message` lines, and `--json` has `status` and `summary.unresolvedRefCount`. From the shipped docs: findings change the exit code only with `--check`, unresolved refs exit 2 either way | `tests/acceptance.sh` requires exit 0 and `unresolved=0,` in the output (`unresolved=0` alone would also match `unresolved=07`) |
| `openclaw update status --json` and `openclaw --version` on a fresh npm install (guest) | exit 0; a JSON object with `update`, `channel`, `availability` and `recoverySets` and **no `lastRun`**: a manual package-manager install creates no updater history (shipped docs), and `lastRun` (`status` is `running`, `succeeded`, `failed`, `rolled-back` or `skipped`) only appears once an update run is recorded, for instance in the state the import restores. `openclaw --version` prints `OpenClaw 2026.9.7 (c074824)` | the plan's check (`"status": "succeeded"` in the JSON) would FAIL on a guest that has never run `openclaw update`; acceptance instead requires that a `lastRun`, when there is one, is `succeeded`, and that the installed version equals `OPENCLAW_VERSION` in `provision/versions.env` |
| `openclaw agent --json`, Gateway-backed (shipped docs and code; **not run**: Task 9 makes no model call) | stdout is the raw Gateway response, `{ runId, status, summary, result: { payloads: [{ text, ... }], meta } }`; logs go to stderr under `--json`; the exit status is 0 only for `ok`/`completed`, and failures are `{ ok: false, error: { type: "cli_error" } }` with exit 1. `--agent main --session-key K` scopes the key to `agent:main:K`. The `agent exec` envelope (not used here) carries `payloads` at the top level | acceptance reads the reply from `result.payloads[].text` (or top-level `payloads[].text`) and requires `pong` there, so an echo of the prompt elsewhere in the JSON cannot pass; the first real rehearsal run is the confirmation |
| `openclaw sessions delete <keys...> --agent ID --yes` (`--help`) | deletes through the running Gateway, takes full `agent:<id>:<key>` keys, `--yes` skips the prompt | acceptance deletes `agent:main:bench:acc-primary` and `agent:main:bench:acc-fallback` with it after the probes, pass or fail, and only warns if that fails |
| `openclaw channels status` with no Gateway credentials (guest, scratch HOME) | **exit 0** while printing `Gateway auth unavailable; showing config-only status.` (or `Gateway not reachable; ...`) and config-only account lines. From the shipped source, a live reply starts `Gateway reachable.` and each account line is `- <Label> <account>[ (name)]: enabled, configured, linked, [reason:..., error:...,] running, connected, ...` (the WhatsApp label is `WhatsApp`); the config-only lines stop after `linked`. **Not yet seen on Linux with a linked WhatsApp account** | the exit status proves nothing: acceptance matches the output against `WA_LINKED_RE` (one named constant in `tests/acceptance.sh`, the guard's own pattern plus `running, connected`); Task 10 checks the real line and corrects the constant, and the guard's `linked,` regex with it |
| `wacli auth status --read-only --json` (wacli 0.13.0, guest) | exit 0 and `{"success":true,"data":{"authenticated":false},"error":null}` when not authenticated. The store is `~/.wacli` when that directory exists and the XDG state dir (`~/.local/state/wacli`) otherwise | acceptance reads `data.authenticated`, not the exit status; the `~/.wacli` the import restores is used without `--store` |

## Bot account facts (2026-10-02)

The counts in this table were read on the live guest on 2026-10-02; the rehearsal re-checks them.

| Fact | Result | Consequence |
|---|---|---|
| Guest accounts | `admin` is uid 501, gid 1000, groups `admin` and `systemd-journal`, with passwordless sudo from Lima's cloud-init; home `/Users/admin` | the bot gets an account of its own, without sudo (`sebastian`, 2000) |
| Bot units | `openclaw-gateway.service` is a systemd user unit with `NoNewPrivileges=no`; the listener guard and the nightly backup are user units too; linger is on for admin | run as admin, the agent could become root; the bot's units move to `sebastian`, whose linger provisioning enables |
| Tailscale | `tailscale debug prefs` shows `OperatorUser` null; with `gateway.tailscale.mode=serve` the gateway refuses to start when its Serve claim fails ("serve failed: Logged out") | provisioning sets `--operator=sebastian` once Tailscale is up; `import.sh final` and `rehome.sh prepare` check it |
| Absolute paths in the live `openclaw.json` | the exec secret-provider command (`/Users/admin/.openclaw/bin/op-nosym`, 6 times), the providers' `trustedDirs` (`/Users/admin/.openclaw/bin`, 6), the workspace (`/Users/admin/.openclaw/workspace`, 2) and the vault (`/Users/admin/brain/vault`, 1) | `migrate/homepaths.mjs` rewrites them; `migrate/scan-refs.mjs --old-home` fails on any left |
| Automations store | in 2026.9.7 automations live in the shared SQLite state (`state/openclaw.sqlite`, `cron_jobs`), partitioned by the absolute key `<home>/.openclaw/cron/jobs.json`; there is no `jobs.json` file; `openclaw cron list --all --json` reads `.total` through the gateway and returns null for a few seconds after a restart | `migrate/state-paths.py` moves the partition key and the other path keys at a cross-home import (rehearsal 2026-10-06, below); counts are read with `cron list`, retried while null |
| State relocation | OpenClaw documents `OPENCLAW_STATE_DIR` relocation; `openclaw memory status` reports `workspaceDir` and `dbPath` as absolute paths; `openclaw memory search` needs `--agent main` (several agents) | acceptance checks the memory paths; the memory-search MANUAL line names `--agent main` |
| `openclaw doctor --non-interactive` | writes | run only with the gateway stopped; the doctor comparison is done on a drill |

### Rehearsal of the move (2026-10-05 and 2026-10-06, `CLAW_INSTANCE=claw-drill` on the dev Mac)

The first run (2026-10-05, the 2026-10-05 night) stopped at step 5 three times, each a real finding that is now fixed:

1. `prepare`'s dry leftover scan named 7 admin files. Owner decision: make them home-relative at the source on production. Later, the memory project annotations in `DREAMS.md` were restored to absolute paths, because project keys are absolute by design. The import now rewrites them.
2. The switch's admin nightly recreated `/tmp/openclaw` as admin, two seconds after it had been moved aside. The bot's gateway then got `EACCES` and could not log. Fix: the move aside now comes after the nightly.
3. After the import the bot's gateway listed 3 automations instead of 21. OpenClaw 2026.9.7 keys SQLite state by absolute path:
   - the cron partition, run receipts and task runs;
   - workspace identity;
   - the exec-approvals socket;
   - Workshop targets;
   - memory and plugin keys that hash the workspace path;
   - Codex bindings and threads.

   Owner decision: a one-time, version-pinned rewrite at import (`migrate/state-paths.py`), with a dry run in `prepare` and a check in `verify`.

The second run (2026-10-06, the 2026-10-06 night, fresh drill) passed every step.

| Step | Result |
|---|---|
| 2 | `provision: changed=22 ok=12`, `stack: OK`; python3 3.13 with sqlite3 |
| 3 | `import: done (drill)`, admin's three units active |
| 4 | baseline as admin: 40 sessions, 21 automations, 10 doctor warning lines |
| 5 | `prepare: OK`: the dry scan is clean; the note walk found 417 notes in 3 workspaces; the state-path preflight ran a dry migration on copies of the live databases (about 47 MB in `/tmp`) |
| 5 | `switch drill`: 21 automations recorded. The migration moved the cron partition (21 jobs, 768 receipts, 1276 task runs), 1 command argv, 2 workspaces, the socket, 27 Workshop proposals, and 3757 + 47 + 14 plugin keys; the post-check passed. 28 files rewritten (scripts, Codex trust, 98 project annotations); 20 config backups set aside |
| 5 | `verify rehearsal`: every automated item PASS; the bot's gateway lists 21 automations, as admin's did; `state-paths check: OK` (7 items) |
| 5a | a nightly as the bot (1.3 GB); the pull streamed it as the bot over `limactl shell` and it passed the MANIFEST gate. The dev Mac had no `restic`, so the snapshot step stopped there; the host's 06:15 pulls snapshot every night |
| 6 | `uid=2000(sebastian) gid=2000(sebastian) groups=2000(sebastian)`; `sudo: a password is required`; nft `Operation not permitted (you must be root)` and `netlink: Error: cache initialization failed: Operation not permitted`; no OpenClaw process outside `sebastian`; `/tmp/openclaw` `sebastian 700`; memory `Indexed: 268/268`, search returns results; 40 sessions and 21 automations (= baseline); `openclaw.json` names `/Users/admin` 0 times; WhatsApp not linked; the wacli store opens |
| 7 | doctor after the switch vs before: no new warning. Both show the same two pre-existing iMessage plugin warnings: its install record names a missing admin-era npm dir; iMessage was dropped |
| 8 | rollback (admin active, 21 automations) → switch → verify PASS → retire (`root 700`, delete after 14 days; admin's home holds only its own dotfiles; `Linger=no`) |
| 9 | rollback after retire (admin's copy back, `Linger=yes`, 21 automations) → switch → verify PASS → retire |
| 10 | after a reboot the bot's gateway was active 3 s after boot, before any login; guard timer active; 21 automations |

Live facts recorded:
- **Gateway argv:** `/usr/bin/node --max-old-space-size=… /usr/lib/node_modules/openclaw/dist/index.js gateway --port 18789`. The acceptance owner item PASSes, which proves `BOT_PROC_RE`. Codex helpers run from `~/.openclaw/npm/…` (as the bot).
- **`channels status`:** exits 0 on a stripped drill.

Not exercisable on a drill without Tailscale, so these are checked on production:
- whether admin can read `tailscale debug prefs` in `prepare`;
- the operator handoff after a rollback.

## Notes

- The user D-Bus socket (`dbus.socket`, user scope) is inactive in the provisioned guest, so `openclaw doctor` prints "Gateway service inspection is unavailable" and skips its service maintenance (the unit that import.sh installs is unaffected). With the socket started, doctor restarts the gateway itself. Decide in provisioning whether to enable it before relying on `openclaw update` to manage the service.
- The newest backup (2026-09-30) was written by OpenClaw runtime 2026.9.5, while the Tart guest now runs 2026.9.7 (pinned in `provision/versions.env`). `openclaw backup restore` accepts it; the restore requires a fresh, non-existent `--target` and its `--json` output carries `ok`, `archiveRoot`, `runtimeVersion`, `entryCount`, `targetPath` and a `warnings` list.
- Restore warnings worth remembering for the import: WhatsApp credentials with ratchet state may desynchronize after rollback and need relinking; approvals and delivery/dedupe state roll back; plugin `node_modules` are not archived (run `openclaw plugins update ID` or reinstall after activation); generated plugin-skills links are not archived (rebuilt by `openclaw skills list` or the first agent session).
- sag compatibility with the `sag` skill: the skill (`skills/sag/SKILL.md` inside the OpenClaw npm package) invokes `sag "text"` (no subcommand, which defaults to `speak`), `sag speak`, `sag voices` and `sag prompting`, with the flags `-v`/`--voice` (name or ID), `-o`/`--output` (write an audio file), `--normalize auto|off`, `--lang`, and `--api-key-file`; it reads the key from `ELEVENLABS_API_KEY` (or `SAG_API_KEY`, or the `ELEVENLABS_API_KEY_FILE` / `SAG_API_KEY_FILE` key files) and the default voice from `ELEVENLABS_VOICE_ID` or `SAG_VOICE_ID`. Comparing `--help` output of the Tart guest's 0.3.0 with the 0.4.0 release (run on the dev Mac) showed an identical flag set for the root command and for `speak`, `voices` and `prompting`; only help text differs: `--base-url` now defaults to empty (provider default), and 0.4.0 adds an optional 60db provider with automatic provider selection (configure exactly one of ElevenLabs or 60db; the guest only has ElevenLabs). Task 4 and the rehearsal must still confirm a real `sag -o FILE "text"` run on the guest, since the skill was not executed against 0.4.0.
- The Tart guest runs Node 26.5.0, while `NODE_MAJOR` is pinned to 24 (the LTS line the plan targets).
- summarize: the Tart guest's 0.21.6 is pinned, although Homebrew's stable formula is now 0.24.0; upgrade after cutover like the other pins.
- A `Persistent=true` timer makes systemd write `~/.local/share/systemd/timers/stamp-<timer>` in the guest user's home (verified for the nightly backup timer); remove `~/.local` when cleaning a scratch guest.

## Rehearsal (2026-10-01)

Rehearsal on the dev Mac, run from a remote site over Tailscale. The home hosts were reachable only through a DERP relay, at about 2.6 MB/s.

| Step | Result |
|---|---|
| Rehearsal export (live gateway) | `export.sh rehearsal` took about 1 min. The export was 1.9 GB and its checksums verified. The free-space check passed. bsdtar warned only about Codex `codex-home` SQLite files being archived as opaque bytes. |
| Safety copy | Copied from the appliance to the old VM over Tailscale on the LAN in 48 s, into `~/Backups/vm-claw-pre-linux/`. Checksums OK, files 600. |
| Tart clone | Gateway bootout, then the doctor baseline, then `tart stop` (graceful), then `tart clone vm-claw vm-claw-pre-linux`, then a bootstrap of the agent. The owner ran this step. The VM was back and WhatsApp linked and connected again about 1 min after the clone. |
| Baseline | Secrets audit clean (0/0/0/0/0), 20 automations, 40 sessions. `doctor --non-interactive` rewrote the gateway's launchd service definition (EnvironmentWrapper, StandardErrorPath), so it is a writer. Run it only while the gateway is stopped. |
| Fresh guest | `destroy`, `create --memory 8`, `start`, `provision`: exit 0, and `tests/stack-check.sh` reported OK for every pin, the compat links and linger. |
| Drill import, run 1 | Died at the health poll. The production config has `gateway.tailscale.mode=serve`, and with the guest's Tailscale logged out the gateway fails with "serve failed: Logged out" and goes into a restart loop. Fixed in import.sh: rehearsal and drill switch serve off; final requires `BackendState=Running`. |
| Drill import, run 2 | Health poll passed. Died at the free-text scan: `ops/listener-guard/listener-guard.mjs` is the old macOS guard (it calls launchctl). Fixed in import.sh: the import now retires that file and its two launchd logs. |
| Drill import, run 3 | Scan reported 0 files. Died at `secrets audit --check`: PLAINTEXT_FOUND for the `openai:models-json` profile (a revoked key; see below). |
| Acceptance (`rehearsal`) | All 7 automated items PASS: secrets audit, update status and version pin, primary and fallback agent probes, firewall against the LAN router, guard dry run, vault deploy key. |
| Hand checks | Main agent DB present. Sessions 40, matching the old VM. wacli store opens read-only with 13,893 messages and 16 chats, and the session is excluded (`disconnected`). WhatsApp is "not linked, stopped", the same line format as on macOS. No iMessage. `cron.enabled=false`. No WhatsApp credential files. Doctor reports no browser or Chromium issue. The guard timer runs and finishes cleanly. `harvest-health.json` has the keys `appended, at, ok, rows`. The only automation `argv[0]` is `/usr/bin/node`. `sag speak -o FILE` produced a valid MP3 on linux-arm64 through the migrated `op-nosym` wrapper. |
| Logs | The gateway writes `/tmp/openclaw/openclaw-<date>.log`, visible from the user shell (no PrivateTmp). The guard's log path holds unchanged. |
| Discard | Guest destroyed. The dev Mac copy of the export was deleted. The appliance safety copy is kept. |

Revoked-key residue: `models auth logout` on 2026-09-30 cleared only the shared auth store. The main agent's `openclaw-agent.sqlite` still holds the `openai:models-json` profile, and the guest's first start merged it back into the shared store. Its bytes also sit in agent `cache_entries` (scope `plugin-model-catalog-v1`, key `openai`) and in five older OpenClaw `.bak` database snapshots.

The cleanup was proven on the guest, with the gateway stopped:
1. `openclaw models auth logout openai:models-json --agent main --yes`
2. Delete that `cache_entries` row.
3. Run `PRAGMA wal_checkpoint(TRUNCATE); VACUUM;` on `state/openclaw.sqlite` and `agents/main/agent/openclaw-agent.sqlite`.

Afterwards no live file held the key, the audit was clean, and the acceptance passed again, including the fallback probe.

At cutover, run the same cleanup on the old VM with its gateway stopped, before the final export.

## First backup cycle and restore drill (2026-10-02)

| Check | Result |
|---|---|
| Guest nightly | `openclaw-nightly-backup.service` ran at 03:30 UTC: Result=success, exit 0, `claw-nightly-<ts>` of 1.2 GB. |
| Host pull | The 06:15 launchd run copied the night to the host and verified it. It saved restic snapshot 1 (1.17 GiB) to iCloud Drive, applied the 14d/8w/12m policy, and wrote the guest stamp `~/backups/.host-pull-ok`. The pull agent read the keychain without trouble in the auto-login session. |
| Backup alert | The 09:00 run recorded `ok (suppressed)`: the check passed, the wrapper printed `NO_REPLY`, and nothing was sent. On day 0 the manual test run delivered the expected `BACKUP ALERT` to WhatsApp. |
| Scheduled jobs | The 08:00 announce jobs ran `ok` and delivered to WhatsApp. `ocsb-harvest` (every 15 min) and `ocsb-ingest` (hourly) both ran `ok`. |
| Gateway | Up since cutover with 0 systemd restarts. WhatsApp is linked, running and connected. The listener guard ran 363 times overnight and never restarted the gateway. |
| Restore drill | The newest nightly went to a scratch instance (`claw-drill`, 4 GiB, provisioned the same way, `stack: OK`). `import.sh rehearsal` refused it ("archive is a 'nightly' export"). `import.sh drill` completed: `tailscale.mode` set to off, scan 0, secrets audit clean. |
| Drill state | WhatsApp is not linked and stopped. `cron.enabled=false`. No WhatsApp credential files and no wacli session. The backup itself does hold the real credentials (`credentials/whatsapp/default/creds.json` counted 1). Automations: 21, the same as live. Sessions: 41, against 42 live; one session was created after the nightly. |
| Cleanup | The scratch instance and the dev Mac copy of the nightly were deleted. |

## OpenClaw 2026.9.7 → 2026.10.2 (2026-10-13, production, as the bot)

- **Before the downtime.**
  - Trial install of 2026.10.2 as the bot into a scratch global prefix, with the strict allow-scripts list: npm exit 0, 341 packages.
  - A nightly as the bot, then the launchd pull and a restic snapshot of it: the way back.
  - Baseline: 40 sessions, 21 automations.
- **Downtime: about 7 minutes.**
  1. Units stopped and proven down, and no OpenClaw process left.
  2. doctor on 9.7, then `provision` (`changed=1`: `openclaw >= 2026.10.2`), then doctor on 10.2.
  3. 10.2's doctor flagged three managed plugins (brave, deepseek, whatsapp) still on 9.7, an unfinished codex plugin data upgrade, and a pending state-schema migration.
  4. `openclaw update repair --yes --no-restart` updated the three plugins.
  5. Its finalize step failed with `EACCES lstat /Users/admin/.openclaw`: the dropped iMessage plugin's install record still pointed into admin's home. `openclaw plugins uninstall imessage --force` removed it, and a second repair exited 0 ("Update finalization completed with warnings").
- **After.**
  - Acceptance final: every automated item PASS, including WhatsApp linked and connected, both agent probes, and the harvest.
  - 21 automations and 40 sessions, both equal to the baseline.
  - `openclaw update status`: up to date, 2026.10.2.
  - Remaining warnings:
    - two historical Workshop workspace records under `/Users/admin`, kept for manual review (the bot cannot read admin's home; accepted);
    - the codex plugin's data upgrade reported as unfinished. The plugin is enabled at 2026.10.2.

## Production: the move to the bot account, retire and cleanup (2026-10-06 → 2026-10-16)

| Step | Result |
|---|---|
| `prepare` (2026-10-06) | First refused: the state-path preflight found the running gateway's `agent_database_leases` rows in its copy of the live databases. Those leases are transient and empty in a backup, so the preflight now drops them from its copy; `migrate` stays strict. Then `prepare: OK`. |
| `switch final` (2026-10-06) | About 4 minutes of downtime. The migration moved the cron partition (21 jobs, 776 receipts, 1341 task runs), 1 command argv, 2 workspaces, the socket, 27 Workshop proposals and 3757 + 48 + 14 plugin keys; the post-check passed. 28 files rewritten, 20 config backups set aside. |
| `verify final` | Every automated item PASS, WhatsApp linked and connected; 21 automations; `state-paths check: OK`. Step 3a: a nightly as the bot, the launchd pull exit 0, a restic snapshot. |
| MANUAL items | A real WhatsApp message got a reply (2026-10-06); the first ocsb-ingest and announce jobs, the bot's first vault push and a silent 09:00 alert (by 2026-10-13); face on the panel and the voice round-trip (2026-10-16). |
| `retire` (2026-10-16) | rc 0: 13 items and 5 unit files to `/var/lib/claw-retired-admin-<date>/` (root, 700); admin's `~/.ssh` holds only `authorized_keys`; admin `Linger=no`. Acceptance final afterwards: every automated item PASS. |
| Retired copy deleted (2026-10-16) | The owner chose not to wait the 14 days. Before: one retired copy, acceptance final PASS. Deleted the retired copy, the bot's `claw-import`, admin's `~/vm-claw` and `~/pre-rehome-stale/` (the originals of the 2026-10-05 home-relative fix). After: `/var/lib` holds only `claw-rehome`; admin's home holds its shell dotfiles, `.ssh` (`authorized_keys` only) and `.cache`, `.config`, `.local`, `.npm`. Of these, `.config/op` (the 1Password CLI's state from when the bot ran as admin), `.local/bin/yt-dlp`, `.cache/openclaw*` and `.npm` are admin-era bot leftovers; the bot has its own copies. |
| Tart retired (2026-10-16, Task 14 of the 2026-09-30 plan) | `tart delete` of the old VM, its pre-Linux clone and the cached base image (about 175 GB); the old VM's and the gateway tunnel's disabled launch agents and the Tart-era safety exports removed; the `vmclaw` Go CLI and the Tart docs removed from the repo. |
