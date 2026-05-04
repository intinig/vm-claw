# `vmclaw` CLI — design spec

**Date:** 2026-05-04
**Status:** Approved (per brainstorming session); pending implementation.
**Pairs with:** [`2026-05-04-hermes-imessage-bridge-vm-design.md`](./2026-05-04-hermes-imessage-bridge-vm-design.md). This spec supersedes Phase 5 tasks 5.1 / 5.2 of that plan, and folds Phase 4 wiring into `vmclaw bootstrap finalize`.

## Goal

Replace the four pre-existing bash scripts (`setup.sh`, `run.sh`, `destroy.sh`, `hermes-setup.sh`) and the planned auto-start LaunchAgent + healthcheck helpers with a single Go CLI binary, `vmclaw`. The CLI owns all repo-managed machinery for the Hermes + iMessage bridge VM project: Tart VM lifecycle, Colima/Docker bootstrap, BlueBubbles webhook secret generation, Hermes `.env` wiring, and end-to-end healthchecks. A `vmclaw bootstrap` orchestrator runs everything automatable in order; `vmclaw bootstrap finalize` handles the post-Phase-2 wiring.

### Non-goals

- Distribution to third parties. This is a single-user macOS-only developer tool, built from source.
- Replacing or wrapping the Hermes container's own setup wizard. The Hermes container's first-run `setup` flow stays as upstream; `vmclaw` interacts only with `~/.hermes/` data.
- Cross-platform support. macOS Apple Silicon only; explicit early failure if run on Linux or Intel-only macs (no graceful degradation needed).
- Automating the manual Phase 2 (Apple ID, Messages.app, BlueBubbles install). Those steps require GUI work and 2FA — they remain in the [bridge VM provisioning runbook](./2026-05-04-hermes-imessage-bridge-vm-design.md#vm-provisioning-runbook).

## Architecture overview

`vmclaw` is a single Go binary built with [Cobra](https://github.com/spf13/cobra). It owns command dispatch, argument parsing, output formatting, and orchestration in Go; it shells out via `os/exec` to external tools that already do their job well (`tart`, `colima`, `docker`, `brew`, `softnet`, `launchctl`).

Logic that lived in bash gets ported into typed Go: the vmnet collision check becomes `func DetectVmnetCollision(...) error` operating on parsed `ifconfig` output, the printed runbook of `hermes-setup.sh` becomes structured logging plus a single block of static text, the `--add-host bridge-vm:<ip>` template lookup becomes a typed call to `vm.IP("bridge-vm")`.

Two-phase bootstrap: `vmclaw bootstrap` runs all automatable pre-manual steps then halts with a printed runbook. `vmclaw bootstrap finalize` runs all post-manual wiring and a final healthcheck. A 32-byte hex webhook secret is generated during `bootstrap` (mode 600 file at `~/.hermes/.bb-webhook-secret`) and reused — never regenerated — by `finalize`.

Each subcommand is internally idempotent. `vmclaw bootstrap` is safe to re-run mid-flow; partial state never blocks progress.

## Command set & behaviors

| Command | Replaces | What it does | Idempotency check |
|---|---|---|---|
| `vmclaw vm create` | `setup.sh` | vmnet collision check; `tart clone cirruslabs/macos-tahoe-base:latest bridge-vm`. | `tart list` already contains `bridge-vm` → log + exit 0. |
| `vmclaw vm run` | `run.sh` | vmnet collision check; foreground `tart run --net-softnet bridge-vm`, inheriting stdin/stdout. | None — always foreground; user Ctrl-Cs. |
| `vmclaw vm destroy` | `destroy.sh` | Confirmation prompt (`--yes` to skip); `tart delete bridge-vm`. | VM doesn't exist → log + exit 0. |
| `vmclaw vm install-agent` | (was Phase 5.1) | Renders LaunchAgent plist, writes to `~/Library/LaunchAgents/com.vm-claw.bridge-vm.plist`, `launchctl load`. | Plist already loaded → log + exit 0. |
| `vmclaw vm uninstall-agent` | new | `launchctl unload` + `rm` of the plist. | Plist absent → log + exit 0. |
| `vmclaw hermes bootstrap` | `hermes-setup.sh` | Brew-installs `colima`/`docker`/`docker-compose` if missing; starts Colima profile `default`; pulls `nousresearch/hermes-agent:latest` and the sandbox image; creates `~/.hermes` (mode 700); creates `hermes-net-default` docker network. | Each sub-step independently idempotent. |
| `vmclaw hermes wire` | (was Phase 4.2) | Reads stashed `~/.hermes/.bb-webhook-secret`; prompts for BlueBubbles password (masked); writes `~/.hermes/.env` with the BlueBubbles connector keys; restarts Hermes gateway container with `--add-host bridge-vm:$(tart ip bridge-vm)` baked in. | If `.env` already has the keys + Hermes gateway already has correct `--add-host` → log "already wired" + exit 0. |
| `vmclaw doctor` | (was Phase 5.2) | OK/FAIL per row: tart binary present; bridge-vm exists; bridge-vm has IP; BlueBubbles reachable from host; docker daemon reachable; Hermes gateway container running; container can resolve `bridge-vm` and reach BlueBubbles. Non-zero exit if any FAIL. | N/A — read-only. |
| `vmclaw bootstrap` | new | Orchestrator. Runs in order: `vm create` → `hermes bootstrap` → `vm install-agent` → generate-or-reuse webhook secret → print Phase 2 runbook → exit 0. | Each underlying subcommand is idempotent. Re-running on a partial state continues from where it stopped. |
| `vmclaw bootstrap finalize` | new | Verifies preconditions (secret stashed, VM has IP, BlueBubbles reachable). If preconditions fail, prints the missing piece + runbook fragment, exits non-zero. If OK, runs `hermes wire` → `doctor`. | If wired and doctor green → log "already finalized". |

### Output style

Per-step `==> <action>` headers; `[OK]` / `[DOING]` / `[SKIP]` / `[FAIL]` line prefixes. Errors propagate via Cobra's `RunE` → top-level handler that prints with one-line `Error: <wrapped chain>` and exits 1.

### Flags / env vars

Cobra-native flag parsing + simple env-var fallback (no `viper`). The vars from the original `hermes-setup.sh` become persistent flags or env vars on the relevant `vmclaw hermes` subcommands:

| Var / flag | Default | Used by |
|---|---|---|
| `BRIDGE_VM_NAME` (env) / `--vm-name` | `bridge-vm` | All `vm` and `hermes wire` and `bootstrap` subcommands |
| `COLIMA_PROFILE` / `--colima-profile` | `default` | `hermes bootstrap` |
| `COLIMA_CPU` / `--colima-cpu` | `4` | `hermes bootstrap` |
| `COLIMA_MEMORY_GB` / `--colima-memory-gb` | `8` | `hermes bootstrap` |
| `COLIMA_DISK_GB` / `--colima-disk-gb` | `80` | `hermes bootstrap` |
| `COLIMA_VM_TYPE` / `--colima-vm-type` | `vz` | `hermes bootstrap` |
| `HERMES_IMAGE` / `--hermes-image` | `nousresearch/hermes-agent:latest` | `hermes bootstrap`, `hermes wire` |
| `HERMES_PROFILE_NAME` / `--hermes-profile` | `default` | `hermes bootstrap`, `hermes wire` |
| `HERMES_HOME` / `--hermes-home` | `~/.hermes` (or `~/.hermes-<profile>`) | `hermes bootstrap`, `hermes wire` |
| `HERMES_GATEWAY_PORT` / `--hermes-gateway-port` | `8642` | `hermes bootstrap`, `hermes wire` |
| `HERMES_DASHBOARD_PORT` / `--hermes-dashboard-port` | `9119` | `hermes bootstrap` |
| `HERMES_NETWORK` / `--hermes-network` | `hermes-net-<profile>` | `hermes bootstrap`, `hermes wire` |

`--yes` flag on `vm destroy` skips the confirmation prompt. `--version` on root prints `vmclaw <semver>+<git-sha>` (injected at build time via `-ldflags`).

## Project layout

```
vm-claw/
├── go.mod                           ← module github.com/intinig/vm-claw
├── go.sum
├── Makefile                         ← build / install / test targets
├── cmd/
│   └── vmclaw/
│       └── main.go                  ← Cobra root, version flag, calls cli.Execute()
├── internal/
│   ├── cli/                         ← Cobra command handlers, no business logic
│   │   ├── root.go                  ← rootCmd + global flags + version
│   │   ├── vm.go                    ← `vmclaw vm` + create/run/destroy/install-agent/uninstall-agent
│   │   ├── hermes.go                ← `vmclaw hermes` + bootstrap/wire
│   │   ├── doctor.go                ← `vmclaw doctor`
│   │   └── bootstrap.go             ← `vmclaw bootstrap` + `vmclaw bootstrap finalize`
│   ├── vm/                          ← Tart wrappers
│   │   ├── tart.go                  ← Create / Run / Destroy / IP / List
│   │   └── vmnet.go                 ← VmnetCollisionCheck (port of the bash function)
│   ├── hermes/                      ← Colima + Docker + Hermes data dir
│   │   ├── colima.go                ← Install / Start / Status
│   │   ├── docker.go                ← image pulls, network create, gateway start
│   │   ├── envfile.go               ← read/write ~/.hermes/.env, mode 600 enforcement
│   │   └── secret.go                ← generate / read / persist webhook secret
│   ├── launchagent/                 ← bridge-vm autostart
│   │   ├── plist.go                 ← rendered, written to ~/Library/LaunchAgents
│   │   └── template.plist           ← embedded via //go:embed
│   └── doctor/                      ← healthcheck rows
│       └── checks.go                ← one Check struct per row
├── docs/
│   └── superpowers/
│       ├── specs/
│       └── plans/
├── CLAUDE.md
├── LICENSE
└── README.md
```

### Layout decisions

- **`cmd/vmclaw/main.go`** — conventional Go layout for tools; the package path matches the binary name.
- **`internal/cli/<domain>.go`** — one file per Cobra namespace, not one per subcommand. Keeps related verbs together; aligns with the nested namespace structure.
- **Domain packages under `internal/`** — `vm`, `hermes`, `launchagent`, `doctor` each own their logic with no Cobra dependency. CLI handlers in `internal/cli/` translate flags into calls into these packages. Each domain testable in isolation.
- **Tests** — `*_test.go` next to source. Unit tests run by default. Integration tests (those that actually shell out to `tart` / `docker`) are tagged `//go:build integration` so `go test ./...` stays fast and offline.
- **`internal/launchagent/template.plist`** — embedded into the binary via `//go:embed`. Subcommand renders with the right binary path and VM name, writes to `~/Library/LaunchAgents/com.vm-claw.bridge-vm.plist`.

## Bootstrap orchestrator behavior

### `vmclaw bootstrap` (pre-Phase-2)

1. **Prerequisites check.** Probe `tart`, `softnet`, `brew` on PATH. Fail fast with install instructions if missing. Run vmnet collision check.
2. **`vm create`.** Skip if `tart list` already contains `bridge-vm`. Otherwise clone `cirruslabs/macos-tahoe-base:latest`. ~25 GB on first run.
3. **`hermes bootstrap`.** Brew install + Colima start + image pulls + `~/.hermes` create + docker network create. Each sub-step independently idempotent.
4. **`vm install-agent`.** Render LaunchAgent plist, write, `launchctl load`. Skip if already loaded.
5. **Generate webhook secret.** If `~/.hermes/.bb-webhook-secret` doesn't exist, generate 32 bytes from `crypto/rand`, hex-encode, write to that path mode 600. If it exists, reuse — never regenerate.
6. **Print runbook.** Multi-paragraph user-facing block: what to do during Phase 2, the webhook secret value highlighted, where the secret is stashed (`~/.hermes/.bb-webhook-secret` for re-reference), and the next-step `vmclaw bootstrap finalize` invocation. Always printed every run.
7. **Exit 0.**

### `vmclaw bootstrap finalize` (post-Phase-2)

1. **Read secret** at `~/.hermes/.bb-webhook-secret`. Fail with "run `vmclaw bootstrap` first" if absent.
2. **Resolve VM IP** via `tart ip bridge-vm`. Fail with "VM not running — `vmclaw vm install-agent` should have loaded the LaunchAgent; run `vmclaw vm run` in another terminal to boot manually" if empty. Validate output matches IPv4 (defensive: some tart versions print error strings to stdout in error states).
3. **Probe BlueBubbles liveness** at `http://<vm-ip>:1234/api/v1/ping` (or whichever no-auth endpoint exists; confirm at implementation time against BlueBubbles' API). Fail with "BlueBubbles not reachable; complete Phase 2's runbook section D" if no response.
4. **Prompt for BlueBubbles password** (masked input via `golang.org/x/term`). Validate by hitting `http://<vm-ip>:1234/api/v1/server/info?password=<entered>`. Re-prompt up to 3 times on 401/403; abort after.
5. **Write `~/.hermes/.env`.** Read existing file, merge in (or replace) the BlueBubbles connector keys: `BLUEBUBBLES_SERVER_URL=http://bridge-vm:1234`, `BLUEBUBBLES_PASSWORD=<entered>`, `BLUEBUBBLES_WEBHOOK_SECRET=<from step 1>`. **Exact key names parameterized as constants in `internal/hermes/envfile.go`** — Phase 4.1 research output is a single small commit updating those constants. Re-confirm `.env` mode is 600.
6. **Restart Hermes gateway container.** `docker stop hermes && docker rm hermes && docker run -d --name hermes ... --add-host bridge-vm:<ip> ...`. The `--add-host` value uses the literal IP resolved in step 2.
7. **Run `doctor`** as the final gate. If all rows OK, print success. If any FAIL, propagate the doctor's exit code so the user knows the e2e isn't actually green.

### Idempotency invariants

- `~/.hermes/.bb-webhook-secret` is generated **once** and reused. Never regenerated. BlueBubbles' webhook config (configured by hand in Phase 2) holds the original value; rotating means the webhook config has to be updated manually too.
- `bootstrap` is safe to re-run: existing VM skipped, existing colima skipped, existing LaunchAgent skipped, existing secret reused, runbook re-printed.
- `bootstrap finalize` is safe to re-run: detects "already wired" (env keys present + Hermes container has the right `--add-host`) and short-circuits to just running `doctor`.

### Failure model

- Each step uses Cobra's `RunE`. Errors wrapped with `fmt.Errorf("vm create: %w", err)`. Top-level error handler prints `Error: <chain>` and exits 1. No silent failures.
- A failed step does **not** roll back. The user re-runs `vmclaw bootstrap` after fixing the issue; idempotency makes that safe.
- The `doctor` check at the end of `finalize` is the single source of truth for "is everything actually working." If it FAILs, finalize itself doesn't claim success.

## Distribution & install

`vmclaw` is built from source. No releases, no pre-built binary committed to the repo.

```
make             # default: go build -o bin/vmclaw ./cmd/vmclaw
make install     # go install ./cmd/vmclaw   (lands in $GOBIN, typically ~/go/bin)
make uninstall   # rm $(go env GOPATH)/bin/vmclaw
make test        # go test ./...                  (unit, fast, offline)
make integration # go test -tags=integration ./... (shells out to tart/docker)
make clean       # rm -rf bin/
```

For getting onto PATH: `make install` once. Adds `vmclaw` to `~/go/bin`, which is on most Go developers' PATH already.

`bin/` is gitignored. The repo only ever ships source.

`vmclaw --version` prints `vmclaw <semver>+<git-sha>` injected at build time via `-ldflags "-X main.version=..."`.

## Migration & backwards compat

**Deleted in this migration:**

- `setup.sh`
- `run.sh`
- `destroy.sh`
- `hermes-setup.sh`

No deprecation stubs, no compat shims. The user is the only operator; there's no third party to migrate.

**Added:**

- `cmd/vmclaw/main.go` and the `internal/` tree above.
- `go.mod`, `go.sum`.
- `Makefile`.
- `.gitignore` updates for `bin/` and any stray `vmclaw` build at root.

**Modified:**

- **`CLAUDE.md`** — "Recovery paths" section: `./host/healthcheck.sh` → `vmclaw doctor`, `./host/install-vm-launchagent.sh` → `vmclaw vm install-agent`. "Architecture" section: drop the four `.sh` lines, add `cmd/vmclaw/`, `internal/`, `Makefile`. "Tart Commands Reference" + "Hermes-Path Configuration Constraints" sections gain a one-line pointer to `vmclaw vm <verb>` / `vmclaw hermes <verb>` as the entry points; underlying tool docs stay informational.
- **`README.md`** — replace bash invocation examples with `vmclaw bootstrap` for the whole automatable path, plus a reference to the Phase 2 runbook. Tunables table maps directly to the flag/env table above.
- **`docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md`** — append a brief "**Update 2026-05-04: superseded by `vmclaw` CLI**" note linking to this spec. Don't rewrite the body; the original is a useful historical record.
- **`docs/superpowers/plans/2026-05-04-hermes-imessage-bridge-vm.md`** — mark Phase 4 tasks 4.1–4.3 and Phase 5 tasks 5.1–5.2 as superseded by the vmclaw migration.

### Sequencing

The vmclaw migration lands **before** the user does Phase 2 manual provisioning, so the runbook is followed using `vmclaw` subcommands rather than the soon-to-be-deleted shell scripts.

1. Land the vmclaw migration (this spec → plan → execution).
2. (Optional, parallelizable with step 1) Phase 4.1 connector-key research; output is a small commit updating constants in `internal/hermes/envfile.go`.
3. User does Phase 2 manually (`vmclaw vm run` to boot the VM, follow the runbook in the bridge-VM design spec).
4. User runs `vmclaw bootstrap finalize`.

## Decisions log

Captured during the brainstorming session that produced this spec.

| Decision | Choice | Reasoning |
|---|---|---|
| Implementation language | Go | User's default; native types beat bash for the gnarlier bits (vmnet check, env file rewriting). |
| Bash backend vs. native Go | Native Go, all 4 bash scripts deleted | Single codebase, idiomatic error handling, structured logs. |
| CLI framework | Cobra | De facto standard; auto help; nested subcommand support; pulls weight at ~10 subcommands. |
| Subcommand naming | Nested by domain (`vmclaw vm <verb>`, `vmclaw hermes <verb>`, top-level `doctor` and `bootstrap`) | Tart and Colima/Docker are genuinely separate stacks; nesting makes the boundary visible. |
| Bootstrap flow | Two explicit phases: `vmclaw bootstrap` and `vmclaw bootstrap finalize` | Manual Phase 2 is unavoidable; explicit phases beat one-command-with-pause for clarity. |
| Webhook secret handling | Auto-generate during `bootstrap` (32 bytes hex, mode 600 file), reuse forever, prompt only for BlueBubbles password during `finalize` | One secret you don't re-type; lower mismatch risk between BlueBubbles webhook config and Hermes `.env`. |
| Project layout | `cmd/vmclaw/main.go` + `internal/{cli,vm,hermes,launchagent,doctor}/` | Conventional Go module structure; CLI handlers separated from domain logic for testability. |
| Distribution | Source only; `make install` → `go install` → `~/go/bin` | Single-user developer tool; release pipeline overkill. |
| Backwards compat | None; bash scripts deleted outright | User is the only operator. |
| Idempotency | Each subcommand internally idempotent; `bootstrap` is re-runnable; webhook secret never regenerated | Re-runnable orchestrator is safer than tracking explicit phase state. |

## Open / deferred items

- **Hermes BlueBubbles connector env var names.** Names like `BLUEBUBBLES_SERVER_URL` / `BLUEBUBBLES_PASSWORD` / `BLUEBUBBLES_WEBHOOK_SECRET` are placeholders. The actual key names come from a manual lookup against current Hermes docs; output is a one-commit update to constants in `internal/hermes/envfile.go`. Deferred per the bridge-VM spec's "Open implementation details" section.
- **BlueBubbles liveness probe path.** The `/api/v1/ping` (or equivalent) endpoint used by `bootstrap finalize` step 3 needs confirmation against BlueBubbles' actual API. Confirm at implementation time; fall back to `/api/v1/server/info?password=<entered>` if no auth-less endpoint exists (probe with the entered password instead, and skip the separate auth validation).
- **Cobra command grouping.** Cobra supports command groups in help output. Worth applying once layout settles: `vm`, `hermes`, `top-level` groups so `vmclaw --help` shows them clustered.


---

**Update 2026-05-04: webhook-auth model corrected.** Phase 4.1 research
against [Hermes' BlueBubbles connector docs](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/bluebubbles)
confirmed there is no shared webhook secret. Hermes authenticates
incoming webhooks by sender identity (DM-pairing or
`BLUEBUBBLES_ALLOWED_USERS`). The webhook listener runs in the Hermes
container on port `8645` at path `/bluebubbles-webhook` (separate
from the gateway on `8642`). The implementation was corrected to
match: webhook-secret machinery removed, webhook port published,
`BLUEBUBBLES_WEBHOOK_HOST=0.0.0.0` written to `~/.hermes/.env`. The
runbook printed by `vmclaw bootstrap` now reflects this.
