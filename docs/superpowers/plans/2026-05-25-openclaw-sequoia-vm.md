# OpenClaw on Sequoia VM — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-scope `vm-claw` from "Hermes-on-host + Tahoe bridge VM" to "OpenClaw running inside a Sequoia VM, Tailscale-isolated."

**Architecture:** Three phases on the `rescope-openclaw-sequoia` branch (already created; spec committed at `041a672`). Phase A is reversible Go code/docs work; Phase B is destructive host cleanup; Phase C is the Sequoia + OpenClaw rebuild and verification. PR opens after Phase A and stays open through B+C; merges only after Phase C verifies green via `vmclaw doctor`.

**Tech Stack:** Go 1.25 (CLI), Cobra (commands), Tart (Apple Silicon VMs), Cirrus OCI base images, Tailscale (cask), `imsg` (steipete tap), OpenClaw (npm-distributed Node service), macOS Application Firewall (`socketfilterfw`).

**Resolved open questions from the spec:**

| # | Question | Resolution |
|---|---|---|
| 1 | OpenClaw install | `npm install -g openclaw@latest` (Node 24 LTS or 22.19+ required). After install: `openclaw onboard --install-daemon` sets up the launchd user service. |
| 2 | imsg install | `brew install steipete/tap/imsg` (Peter Steinberger's tap, per OpenClaw iMessage docs). |
| 3 | Tailscale on Sequoia | `brew install --cask tailscale-app` (standalone variant, NOT App Store). One-time GUI approval needed for the system network extension (System Settings → Network → Filters), then headless `tailscale up --auth-key=...` works. |
| 4 | Sequoia base image | `ghcr.io/cirruslabs/macos-sequoia-base:latest`, pinned to a specific digest captured in Task A5. |
| 5 | Tailscale auth-key UX | Support both `--auth-key=tskey-...` (env-equivalent flag, value redacted in logs) and `--auth-key-file=/path/to/file` (file read once). Error if neither provided. |
| 6 | Sample OpenClaw config | Authored in Task A12 as `docs/openclaw-config.example.yaml`. |

---

## File Structure

### Files deleted
- `internal/hermes/colima.go`
- `internal/hermes/docker.go`
- `internal/hermes/envfile.go`
- `internal/hermes/envfile_test.go`
- `internal/hermes/` (empty directory removed)
- `internal/cli/hermes.go`

### Files modified
- `cmd/vmclaw/main.go` — unchanged in scope; verify after refactor
- `internal/cli/root.go` — drop `hermes` subcommand wiring
- `internal/cli/bootstrap.go` — re-orchestrate without Hermes path
- `internal/cli/vm.go` — IPSW/base image defaults switched to Sequoia
- `internal/cli/doctor.go` — wire new checks
- `internal/vm/tart.go` — base image default switched to Sequoia digest
- `internal/launchagent/plist.go` — `DefaultLabel` becomes `com.vm-claw.agent`; VM name templated
- `internal/launchagent/template.plist` — VM name templated
- `internal/launchagent/plist_test.go` — update expectations for new label
- `internal/doctor/checks.go` — replace check set
- `Makefile` — no changes expected
- `go.mod`, `go.sum` — remove unused imports if any
- `CLAUDE.md` — full rewrite
- `README.md` — full rewrite
- `docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md` — already superseded (header added in spec commit)

### Files created
- `internal/vm/brew.go` — `EnsureBrew(ctx, exec)`, `EnsureBrewPackages(ctx, exec, packages...)`, `EnsureBrewCask(ctx, exec, cask)` (moved + lightly renamed from `internal/hermes/colima.go`)
- `internal/vm/brew_test.go` — tests for the brew helpers
- `internal/vm/firewall.go` — `EnableBlockAllIncoming(ctx, exec)`, `AllowApp(ctx, exec, appPath)`, `IsBlockAllIncoming(ctx, exec) (bool, error)`
- `internal/vm/firewall_test.go` — tests for firewall parsing
- `internal/tailscale/setup.go` — `Install(ctx, exec)`, `Up(ctx, exec, authKey, tag string)`, `Status(ctx, exec) (Status, error)`
- `internal/tailscale/setup_test.go` — tests
- `internal/cli/tailscale.go` — `vmclaw vm tailscale-bootstrap` Cobra command
- `internal/cli/tailscale_test.go` — flag-parsing tests
- `docs/openclaw-config.example.yaml` — config template referenced by README's manual runbook
- `docs/runbook-openclaw-install.md` — manual steps Phase C, items C7–C11

---

## Phase A — Repo Rescope (Go + docs)

Work happens on the `rescope-openclaw-sequoia` branch. Every task ends with a commit. PR opens at the end of Phase A.

### Task A1: Delete the `internal/hermes/` package

**Files:**
- Delete: `internal/hermes/colima.go`, `internal/hermes/docker.go`, `internal/hermes/envfile.go`, `internal/hermes/envfile_test.go`
- Delete: `internal/hermes/` directory

- [ ] **Step 1: Confirm no production callers remain after we move brew helpers**

Run: `cd /Users/gintini/s/vm-claw && grep -rn "internal/hermes" --include='*.go' .`
Expected: hits in `internal/cli/bootstrap.go`, `internal/cli/hermes.go`, `internal/cli/doctor.go` — these are removed in later tasks.

- [ ] **Step 2: Move brew helpers out before deletion (see Task A2 — execute A2 first, then return here)**

This task is **blocked** by Task A2. Skip ahead and complete A2, then return.

- [ ] **Step 3: Delete the hermes package files**

```bash
cd /Users/gintini/s/vm-claw
rm internal/hermes/colima.go internal/hermes/docker.go internal/hermes/envfile.go internal/hermes/envfile_test.go
rmdir internal/hermes
```

- [ ] **Step 4: Verify deletion**

Run: `ls internal/hermes 2>&1 || echo gone`
Expected: `gone`

- [ ] **Step 5: Commit**

```bash
git add -A internal/hermes
git commit -m "Remove internal/hermes package (Hermes-era code)"
```

### Task A2: Extract brew helpers to `internal/vm/brew.go`

`internal/hermes/colima.go` contains `EnsureBrewInstalled` and `EnsurePackagesInstalled` — generic over `vm.Executor`. We need them for installing Tailscale + imsg inside the new VM. Move and rename.

**Files:**
- Create: `internal/vm/brew.go`
- Create: `internal/vm/brew_test.go`

- [ ] **Step 1: Write the failing test**

Create `internal/vm/brew_test.go`:

```go
package vm

import (
	"context"
	"strings"
	"testing"
)

type fakeExec struct {
	calls   []string
	outputs map[string]string
	errs    map[string]error
}

func (f *fakeExec) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := name + " " + strings.Join(args, " ")
	f.calls = append(f.calls, cmd)
	if err, ok := f.errs[cmd]; ok {
		return nil, err
	}
	return []byte(f.outputs[cmd]), nil
}

func TestEnsureBrew_AlreadyInstalled(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{"brew --version": "Homebrew 4.0.0\n"}}
	if err := EnsureBrew(context.Background(), fx); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(fx.calls) != 1 || fx.calls[0] != "brew --version" {
		t.Fatalf("expected only brew --version, got %v", fx.calls)
	}
}

func TestEnsureBrewPackages_InstallsMissing(t *testing.T) {
	fx := &fakeExec{
		outputs: map[string]string{
			"brew list --formula imsg":          "",
			"brew install steipete/tap/imsg":    "",
		},
		errs: map[string]error{"brew list --formula imsg": errNotInstalled},
	}
	if err := EnsureBrewPackages(context.Background(), fx, "steipete/tap/imsg"); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	got := strings.Join(fx.calls, " | ")
	if !strings.Contains(got, "brew install steipete/tap/imsg") {
		t.Fatalf("expected install call, got: %s", got)
	}
}

func TestEnsureBrewCask_Installs(t *testing.T) {
	fx := &fakeExec{
		outputs: map[string]string{
			"brew list --cask tailscale-app":    "",
			"brew install --cask tailscale-app": "",
		},
		errs: map[string]error{"brew list --cask tailscale-app": errNotInstalled},
	}
	if err := EnsureBrewCask(context.Background(), fx, "tailscale-app"); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	got := strings.Join(fx.calls, " | ")
	if !strings.Contains(got, "brew install --cask tailscale-app") {
		t.Fatalf("expected cask install call, got: %s", got)
	}
}
```

- [ ] **Step 2: Run tests, expect FAIL**

Run: `cd /Users/gintini/s/vm-claw && go test ./internal/vm/ -run 'TestEnsureBrew' -v`
Expected: compile error — `errNotInstalled`, `EnsureBrew`, `EnsureBrewPackages`, `EnsureBrewCask` undefined.

- [ ] **Step 3: Write the implementation**

Create `internal/vm/brew.go`:

```go
package vm

import (
	"context"
	"errors"
	"fmt"
)

var errNotInstalled = errors.New("not installed")

// EnsureBrew returns nil if Homebrew is reachable via the given Executor.
// It does NOT auto-install Homebrew (that requires curl-pipe-bash with sudo).
func EnsureBrew(ctx context.Context, exec Executor) error {
	if _, err := exec.Run(ctx, "brew", "--version"); err != nil {
		return fmt.Errorf("homebrew not available: %w", err)
	}
	return nil
}

// EnsureBrewPackages installs missing brew formulas. Idempotent.
func EnsureBrewPackages(ctx context.Context, exec Executor, packages ...string) error {
	for _, pkg := range packages {
		if _, err := exec.Run(ctx, "brew", "list", "--formula", pkg); err == nil {
			continue
		}
		if _, err := exec.Run(ctx, "brew", "install", pkg); err != nil {
			return fmt.Errorf("brew install %s: %w", pkg, err)
		}
	}
	return nil
}

// EnsureBrewCask installs a cask if not present. Idempotent.
func EnsureBrewCask(ctx context.Context, exec Executor, cask string) error {
	if _, err := exec.Run(ctx, "brew", "list", "--cask", cask); err == nil {
		return nil
	}
	if _, err := exec.Run(ctx, "brew", "install", "--cask", cask); err != nil {
		return fmt.Errorf("brew install --cask %s: %w", cask, err)
	}
	return nil
}
```

- [ ] **Step 4: Run tests, expect PASS**

Run: `cd /Users/gintini/s/vm-claw && go test ./internal/vm/ -run 'TestEnsureBrew' -v`
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/vm/brew.go internal/vm/brew_test.go
git commit -m "vm: extract brew helpers from hermes/colima.go"
```

### Task A3: Delete `internal/cli/hermes.go` and its registration

**Files:**
- Delete: `internal/cli/hermes.go`
- Modify: `internal/cli/root.go` (remove hermes subcommand wiring)

- [ ] **Step 1: Identify root.go references**

Run: `cd /Users/gintini/s/vm-claw && grep -n hermes internal/cli/root.go`
Expected: zero or a handful of lines registering the `hermes` cobra subcommand.

- [ ] **Step 2: Read root.go**

Read `/Users/gintini/s/vm-claw/internal/cli/root.go` and capture the full hermes-registration block.

- [ ] **Step 3: Remove hermes references from root.go**

Use the `Edit` tool to remove any `rootCmd.AddCommand(hermesCmd)` line and the `import` of any unused symbols.

- [ ] **Step 4: Delete the hermes CLI file**

```bash
rm /Users/gintini/s/vm-claw/internal/cli/hermes.go
```

- [ ] **Step 5: Build**

Run: `cd /Users/gintini/s/vm-claw && go build ./...`
Expected: compile error in `internal/cli/bootstrap.go` referencing hermes types/functions (fixed in next task). Note the error; that's the next task's input.

- [ ] **Step 6: Stage and continue (do not commit yet — bootstrap.go is broken)**

This task does not commit on its own. The commit happens at the end of Task A4 once bootstrap.go compiles again.

### Task A4: Refactor `internal/cli/bootstrap.go` to remove Hermes orchestration

`bootstrap.go` is 327 lines; ~half is Hermes-specific. New behavior: `vmclaw bootstrap` does VM create → install LaunchAgent → run → wait for IP → prints runbook pointer.

**Files:**
- Modify: `internal/cli/bootstrap.go` (substantial rewrite)

- [ ] **Step 1: Read the current bootstrap.go in full**

Read `/Users/gintini/s/vm-claw/internal/cli/bootstrap.go`.

- [ ] **Step 2: Identify the keep/drop boundary**

Keep: VM lifecycle calls (`tart.Clone`, `tart.IP`, LaunchAgent install). Drop: `probeBlueBubblesLiveness`, `containerRunning`, `alreadyWired`, `runHermesWireCmd`, `printPhase2Runbook` (Hermes-specific). Replace `printPhase2Runbook` with a new `printOpenClawRunbook` that points to `docs/runbook-openclaw-install.md`.

- [ ] **Step 3: Rewrite bootstrap.go**

Replace the file contents. New skeleton:

```go
package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/intinig/vm-claw/internal/launchagent"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
)

const (
	defaultVMName    = "vm-claw"
	defaultBaseImage = "ghcr.io/cirruslabs/macos-sequoia-base:latest" // pin in Task A5
)

func init() {
	bootstrapCmd := &cobra.Command{
		Use:   "bootstrap",
		Short: "Create the Sequoia VM, install LaunchAgent, and print the OpenClaw install runbook",
		RunE:  runBootstrap,
	}
	finalizeCmd := &cobra.Command{
		Use:   "finalize",
		Short: "Idempotent post-rebuild verification (calls doctor + smoke)",
		RunE:  runBootstrapFinalize,
	}
	bootstrapCmd.AddCommand(finalizeCmd)
	rootCmd.AddCommand(bootstrapCmd)
}

func runBootstrap(cmd *cobra.Command, _ []string) error {
	ctx, cancel := context.WithTimeout(cmd.Context(), 15*time.Minute)
	defer cancel()
	out := cmd.OutOrStdout()
	t := vm.NewTart()

	exists, err := t.Exists(ctx, defaultVMName)
	if err != nil {
		return fmt.Errorf("tart list: %w", err)
	}
	if !exists {
		fmt.Fprintf(out, "Cloning %s from %s ...\n", defaultVMName, defaultBaseImage)
		if err := t.Clone(ctx, defaultBaseImage, defaultVMName); err != nil {
			return fmt.Errorf("tart clone: %w", err)
		}
	} else {
		fmt.Fprintf(out, "VM %s already exists, skipping clone\n", defaultVMName)
	}

	bridge, err := resolveBridgeInterface()
	if err != nil {
		return fmt.Errorf("resolve bridge interface: %w", err)
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	tartPath, err := lookPath("tart")
	if err != nil {
		return err
	}
	opts := launchagent.Options{
		Label:       launchagent.DefaultLabel,
		TartPath:    tartPath,
		VMName:      defaultVMName,
		BridgeIface: bridge,
	}
	if err := launchagent.Install(ctx, vm.DefaultExecutor, home, opts); err != nil {
		return fmt.Errorf("install launchagent: %w", err)
	}
	fmt.Fprintln(out, "LaunchAgent installed and loaded.")

	ip, err := waitForIP(ctx, t, defaultVMName, 5*time.Minute)
	if err != nil {
		return fmt.Errorf("waiting for VM IP: %w", err)
	}
	fmt.Fprintf(out, "VM %s is up at %s\n", defaultVMName, ip)

	printOpenClawRunbook(out, ip)
	return nil
}

func runBootstrapFinalize(cmd *cobra.Command, _ []string) error {
	// Run the doctor with smoke option.
	cmd.SilenceUsage = true
	return runDoctor(cmd, []string{"--smoke"})
}

func waitForIP(ctx context.Context, t *vm.Tart, name string, timeout time.Duration) (string, error) {
	deadline := time.Now().Add(timeout)
	for {
		ip, err := t.IP(ctx, name)
		if err == nil && ip != "" {
			return ip, nil
		}
		if time.Now().After(deadline) {
			return "", errors.New("timed out waiting for VM IP")
		}
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(3 * time.Second):
		}
	}
}

func lookPath(bin string) (string, error) {
	// Wrap exec.LookPath so tests can stub.
	return execLookPath(bin)
}

func printOpenClawRunbook(out io.Writer, ip string) {
	fmt.Fprintf(out, `
Next steps (manual):
  1) Open the VM GUI window, sign into the bridge Apple ID, enable iMessage.
  2) From this host, run:
       vmclaw vm tailscale-bootstrap --auth-key-file=<path-to-key>
  3) Then SSH into the VM via tailnet and follow:
       docs/runbook-openclaw-install.md
  4) When green:
       vmclaw doctor

VM IP (bridged LAN): %s
`, ip)
}
```

Plus add a small `execLookPath` helper:

```go
// at the bottom of the file
import_alias_for_exec "os/exec" // (use the normal alias; this is just for the snippet)

func execLookPath(bin string) (string, error) {
	return import_alias_for_exec.LookPath(bin)
}
```

Use the real import alias `exec` for `os/exec`.

- [ ] **Step 4: Build**

Run: `cd /Users/gintini/s/vm-claw && go build ./...`
Expected: clean build.

- [ ] **Step 5: Run existing tests**

Run: `cd /Users/gintini/s/vm-claw && go test ./...`
Expected: all green. If `internal/cli/doctor.go` references `readBBPasswordFromEnvFile`, comment-out that function or remove it (it's dead now) — see Task A7.

- [ ] **Step 6: Commit**

```bash
git add internal/cli/hermes.go internal/cli/bootstrap.go internal/cli/root.go
git rm --cached internal/cli/hermes.go 2>/dev/null; true
git status
git commit -m "Refactor bootstrap to OpenClaw-on-Sequoia orchestration; remove cli/hermes.go"
```

### Task A5: Pin Sequoia base image to a specific digest

Update `defaultBaseImage` constant to a specific digest for reproducibility.

**Files:**
- Modify: `internal/cli/bootstrap.go` (or wherever `defaultBaseImage` lives)

- [ ] **Step 1: Resolve the digest**

Run: `tart pull ghcr.io/cirruslabs/macos-sequoia-base:latest && tart list 2>&1 | grep sequoia`
Expected: row with `OCI ghcr.io/cirruslabs/macos-sequoia-base:latest` AND a sha256 digest. Copy the sha256 string.

If `tart pull` returns non-zero with "manifest unknown" or similar, check the Cirrus Labs registry at `https://github.com/cirruslabs/macos-image-templates/pkgs/container/macos-sequoia-base` for the actual tag name (sometimes it's `macos-sequoia-vanilla:latest` or version-tagged like `:15.6.1`).

- [ ] **Step 2: Pin the digest in code**

```go
const defaultBaseImage = "ghcr.io/cirruslabs/macos-sequoia-base@sha256:<digest from Step 1>"
```

- [ ] **Step 3: Build + test**

Run: `cd /Users/gintini/s/vm-claw && go build ./... && go test ./...`
Expected: green.

- [ ] **Step 4: Commit**

```bash
git add internal/cli/bootstrap.go
git commit -m "Pin Sequoia base image to specific digest for reproducibility"
```

### Task A6: Rename LaunchAgent label and template the VM name

Existing `DefaultLabel = "com.vm-claw.bridge-vm"`. New label: `com.vm-claw.agent`. Template the VM name.

**Files:**
- Modify: `internal/launchagent/plist.go`
- Modify: `internal/launchagent/template.plist`
- Modify: `internal/launchagent/plist_test.go`

- [ ] **Step 1: Update test expectations**

Read `internal/launchagent/plist_test.go` and replace any literal `bridge-vm` or `com.vm-claw.bridge-vm` with `vm-claw` and `com.vm-claw.agent` respectively. Add a test that the template renders the VM name from `Options.VMName`:

```go
func TestRender_VMName(t *testing.T) {
	out, err := render(Options{
		Label:       "com.vm-claw.agent",
		TartPath:    "/opt/homebrew/bin/tart",
		VMName:      "vm-claw",
		BridgeIface: "en0",
	})
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	body := string(out)
	if !strings.Contains(body, "<string>vm-claw</string>") {
		t.Fatalf("expected VMName in plist, got:\n%s", body)
	}
	if strings.Contains(body, "bridge-vm") {
		t.Fatalf("unexpected legacy bridge-vm in plist:\n%s", body)
	}
}
```

- [ ] **Step 2: Run tests, expect FAIL**

Run: `cd /Users/gintini/s/vm-claw && go test ./internal/launchagent/ -run TestRender -v`
Expected: FAIL — template still hardcodes `bridge-vm`.

- [ ] **Step 3: Read and update the template**

Read `internal/launchagent/template.plist`. Find the `<array>` block around `--net-bridged` and replace any hardcoded `bridge-vm` with `{{.VMName}}`.

Expected ProgramArguments after edit:
```xml
<array>
  <string>{{.TartPath}}</string>
  <string>run</string>
  <string>--net-bridged={{.BridgeIface}}</string>
  <string>{{.VMName}}</string>
</array>
```

- [ ] **Step 4: Update `plist.go` constant + Options struct**

```go
const DefaultLabel = "com.vm-claw.agent"

type Options struct {
	Label       string
	TartPath    string
	VMName      string
	BridgeIface string
}
```

(`VMName` is the new field. If `Options` already had a `BridgeVM` or similar field for the same purpose, rename it to `VMName`.)

- [ ] **Step 5: Run tests, expect PASS**

Run: `cd /Users/gintini/s/vm-claw && go test ./internal/launchagent/ -v`
Expected: all PASS.

- [ ] **Step 6: Build the whole project**

Run: `cd /Users/gintini/s/vm-claw && go build ./...`
Expected: clean.

- [ ] **Step 7: Commit**

```bash
git add internal/launchagent/
git commit -m "launchagent: rename label to com.vm-claw.agent, template VM name"
```

### Task A7: Replace doctor checks

`internal/doctor/checks.go` `DefaultChecks(cfg Config)` returns the old check set. Replace it with the new set per the spec.

**Files:**
- Modify: `internal/doctor/checks.go`
- Modify: `internal/cli/doctor.go` (drop `readBBPasswordFromEnvFile` if dead)

- [ ] **Step 1: Read both files in full**

Read `internal/doctor/checks.go` (225 lines) and `internal/cli/doctor.go` (69 lines).

- [ ] **Step 2: Catalog existing checks**

Run: `cd /Users/gintini/s/vm-claw && grep -nE '(Name:|Check:|func.*Check)' internal/doctor/checks.go`
Expected: a list of the current check names. Capture them.

- [ ] **Step 3: Replace `DefaultChecks` to match the spec's Section "Doctor Checks"**

Implement these 20 checks (spec lists them — paraphrased here):

1. `tart-binary-on-path`
2. `host-macos-tahoe-or-newer`
3. `default-route-iface-detected`
4. `tailscale-cli-on-host`
5. `host-tailnet-up`
6. `vm-exists` (tart list grep)
7. `vm-running`
8. `vm-bridged-ip-present`
9. `launchagent-loaded`
10. `vm-os-is-sequoia` (over SSH or tart exec: `sw_vers -productVersion` starts with `15.`)
11. `vm-messages-imessage-active` (probe `defaults read com.apple.iChat`)
12. `vm-tailscale-status-joined`
13. `vm-firewall-block-all-incoming`
14. `vm-openclaw-gateway-running`
15. `vm-openclaw-binds-to-tailscale-or-loopback` (parse `lsof -iTCP -sTCP:LISTEN`)
16. `vm-openclaw-config-hardened` (yaml grep for required keys)
17. `vm-openclaw-version-not-fresh` (npm registry promotion timestamp check)
18. `bridged-port-unreachable` (negative connectivity)
19. `tailnet-port-reachable`
20. `vm-outbound-works` (curl an external endpoint)

Add a `--smoke` flag handler in `internal/cli/doctor.go` that runs an extra check sending a known iMessage wake-word and verifying OpenClaw responds — leave this as a TODO_in_code with a clear marker `// TODO(smoke): real iMessage round-trip needs the bridge Apple ID context; see runbook section 6.` (This is the one acceptable TODO — it's a smoke-test capability that requires an external Apple device.)

- [ ] **Step 4: Write the implementation incrementally**

Replace `DefaultChecks` body. Each check is a `Check` function returning a `Result`. Keep the existing `Result` and `Status` types intact. Use `vm.DefaultExecutor` for shell-outs. For inside-VM probes, use `tart exec <vmName> -- <cmd>` via the same Executor.

Sample for check #6:
```go
{
	Name: "vm-exists",
	Check: func(ctx context.Context) Result {
		t := vm.NewTart()
		ok, err := t.Exists(ctx, cfg.VMName)
		if err != nil {
			return Result{Status: StatusFail, Detail: err.Error()}
		}
		if !ok {
			return Result{Status: StatusFail, Detail: fmt.Sprintf("tart list does not show %q", cfg.VMName)}
		}
		return Result{Status: StatusOK}
	},
},
```

Repeat the same pattern for the rest. The `Config` struct gains `VMName`, `OpenClawPort`, `OpenClawTailnetHost` fields.

- [ ] **Step 5: Drop dead code in `internal/cli/doctor.go`**

`readBBPasswordFromEnvFile` was for BlueBubbles auth probing. No longer used. Delete it.

- [ ] **Step 6: Build + test**

Run: `cd /Users/gintini/s/vm-claw && go build ./... && go test ./...`
Expected: clean. New checks need tests in a follow-up subtask if any have non-trivial parsing logic.

- [ ] **Step 7: Commit**

```bash
git add internal/doctor/ internal/cli/doctor.go
git commit -m "doctor: replace Hermes/Colima checks with OpenClaw/Tailscale/firewall set"
```

### Task A8: Add `internal/vm/firewall.go`

macOS Application Firewall wrapper around `/usr/libexec/ApplicationFirewall/socketfilterfw`.

**Files:**
- Create: `internal/vm/firewall.go`
- Create: `internal/vm/firewall_test.go`

- [ ] **Step 1: Write the failing tests**

Create `internal/vm/firewall_test.go`:

```go
package vm

import (
	"context"
	"strings"
	"testing"
)

func TestIsBlockAllIncoming_True(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{
		"/usr/libexec/ApplicationFirewall/socketfilterfw --getblockall": "Firewall is set to block all non-essential incoming connections\n",
	}}
	got, err := IsBlockAllIncoming(context.Background(), fx)
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if !got {
		t.Fatalf("expected true")
	}
}

func TestIsBlockAllIncoming_False(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{
		"/usr/libexec/ApplicationFirewall/socketfilterfw --getblockall": "Firewall is set to allow incoming connections\n",
	}}
	got, err := IsBlockAllIncoming(context.Background(), fx)
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if got {
		t.Fatalf("expected false")
	}
}

func TestEnableBlockAllIncoming_SetsFlag(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{
		"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on":  "",
		"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall on":     "",
		"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned off": "",
	}}
	if err := EnableBlockAllIncoming(context.Background(), fx); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	got := strings.Join(fx.calls, " | ")
	for _, want := range []string{"--setglobalstate on", "--setblockall on"} {
		if !strings.Contains(got, want) {
			t.Fatalf("expected %q in calls, got: %s", want, got)
		}
	}
}
```

- [ ] **Step 2: Run tests, expect FAIL (undefined)**

Run: `cd /Users/gintini/s/vm-claw && go test ./internal/vm/ -run TestIsBlockAll -v`
Expected: compile error — `IsBlockAllIncoming`, `EnableBlockAllIncoming` undefined.

- [ ] **Step 3: Implement**

Create `internal/vm/firewall.go`:

```go
package vm

import (
	"context"
	"fmt"
	"strings"
)

const firewallBin = "/usr/libexec/ApplicationFirewall/socketfilterfw"

// IsBlockAllIncoming reports whether the macOS Application Firewall is set
// to block all non-essential incoming connections.
func IsBlockAllIncoming(ctx context.Context, exec Executor) (bool, error) {
	out, err := exec.Run(ctx, firewallBin, "--getblockall")
	if err != nil {
		return false, fmt.Errorf("socketfilterfw --getblockall: %w", err)
	}
	return strings.Contains(strings.ToLower(string(out)), "block all"), nil
}

// EnableBlockAllIncoming enables the firewall and sets block-all-incoming.
// Requires root (sudo) because socketfilterfw mutates a system-level setting.
func EnableBlockAllIncoming(ctx context.Context, exec Executor) error {
	steps := [][]string{
		{"sudo", firewallBin, "--setglobalstate", "on"},
		{"sudo", firewallBin, "--setblockall", "on"},
		{"sudo", firewallBin, "--setallowsigned", "off"}, // tighter: even signed apps must be explicitly allowed
	}
	for _, args := range steps {
		if _, err := exec.Run(ctx, args[0], args[1:]...); err != nil {
			return fmt.Errorf("%s: %w", strings.Join(args, " "), err)
		}
	}
	return nil
}

// AllowApp explicitly adds an app to the firewall's allowed list.
func AllowApp(ctx context.Context, exec Executor, appPath string) error {
	if _, err := exec.Run(ctx, "sudo", firewallBin, "--add", appPath); err != nil {
		return fmt.Errorf("socketfilterfw --add %s: %w", appPath, err)
	}
	if _, err := exec.Run(ctx, "sudo", firewallBin, "--unblockapp", appPath); err != nil {
		return fmt.Errorf("socketfilterfw --unblockapp %s: %w", appPath, err)
	}
	return nil
}
```

- [ ] **Step 4: Run tests, expect PASS**

Run: `cd /Users/gintini/s/vm-claw && go test ./internal/vm/ -run 'TestIsBlockAll|TestEnableBlockAll' -v`
Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/vm/firewall.go internal/vm/firewall_test.go
git commit -m "vm: add Application Firewall wrapper (socketfilterfw)"
```

### Task A9: Add `internal/tailscale/setup.go`

Tailscale install + `tailscale up` + status, all over an `Executor` (so it can run via `tart exec` inside the VM).

**Files:**
- Create: `internal/tailscale/setup.go`
- Create: `internal/tailscale/setup_test.go`

- [ ] **Step 1: Write failing tests**

Create `internal/tailscale/setup_test.go`:

```go
package tailscale

import (
	"context"
	"errors"
	"strings"
	"testing"
)

type fakeExec struct {
	calls   []string
	outputs map[string]string
	errs    map[string]error
}

func (f *fakeExec) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := name + " " + strings.Join(args, " ")
	f.calls = append(f.calls, cmd)
	if err, ok := f.errs[cmd]; ok {
		return nil, err
	}
	return []byte(f.outputs[cmd]), nil
}

func TestStatus_Joined(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{
		"tailscale status --json": `{"BackendState":"Running","Self":{"HostName":"vm-claw","TailscaleIPs":["100.64.1.5"]}}`,
	}}
	s, err := Status(context.Background(), fx)
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if s.BackendState != "Running" || s.Hostname != "vm-claw" {
		t.Fatalf("got %+v", s)
	}
}

func TestStatus_NotJoined(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{
		"tailscale status --json": `{"BackendState":"NeedsLogin"}`,
	}}
	s, err := Status(context.Background(), fx)
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if s.BackendState != "NeedsLogin" {
		t.Fatalf("got %+v", s)
	}
}

func TestUp_RedactsAuthKey(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{}}
	err := Up(context.Background(), fx, "tskey-auth-secret", "tag:vm-claw")
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	for _, c := range fx.calls {
		// The actual command passed to exec includes the key; that's required.
		// What must NOT happen is the key appearing in any returned error or log.
		_ = c
	}
}

func TestUp_NoAuthKey_Errors(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{}}
	err := Up(context.Background(), fx, "", "tag:vm-claw")
	if !errors.Is(err, ErrAuthKeyRequired) {
		t.Fatalf("expected ErrAuthKeyRequired, got %v", err)
	}
}
```

- [ ] **Step 2: Run tests, expect FAIL**

Run: `cd /Users/gintini/s/vm-claw && go test ./internal/tailscale/ -v`
Expected: compile error — package doesn't exist yet.

- [ ] **Step 3: Implement**

Create `internal/tailscale/setup.go`:

```go
package tailscale

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/intinig/vm-claw/internal/vm"
)

// ErrAuthKeyRequired is returned by Up when no auth key is supplied.
var ErrAuthKeyRequired = errors.New("tailscale: auth key required")

type Status struct {
	BackendState string
	Hostname     string
	TailscaleIPs []string
}

// Install ensures the tailscale-app cask is present. Idempotent.
// The first launch (to approve the network extension) is a manual GUI step.
func Install(ctx context.Context, exec vm.Executor) error {
	return vm.EnsureBrewCask(ctx, exec, "tailscale-app")
}

// Up runs `tailscale up` with the given auth key and tag.
// Auth key is consumed once; redacted from any wrapped error.
func Up(ctx context.Context, exec vm.Executor, authKey, advertiseTag string) error {
	if authKey == "" {
		return ErrAuthKeyRequired
	}
	args := []string{
		"up",
		"--auth-key=" + authKey,
		"--ssh", // enable Tailscale SSH for ops access
	}
	if advertiseTag != "" {
		args = append(args, "--advertise-tags="+advertiseTag)
	}
	if _, err := exec.Run(ctx, "tailscale", args...); err != nil {
		return redactAuthKey(fmt.Errorf("tailscale up: %w", err), authKey)
	}
	return nil
}

// Status returns the current tailscale status by parsing `tailscale status --json`.
func Status(ctx context.Context, exec vm.Executor) (Status, error) {
	out, err := exec.Run(ctx, "tailscale", "status", "--json")
	if err != nil {
		return Status{}, fmt.Errorf("tailscale status: %w", err)
	}
	var raw struct {
		BackendState string `json:"BackendState"`
		Self         struct {
			HostName     string   `json:"HostName"`
			TailscaleIPs []string `json:"TailscaleIPs"`
		} `json:"Self"`
	}
	if err := json.Unmarshal(out, &raw); err != nil {
		return Status{}, fmt.Errorf("parse tailscale status: %w", err)
	}
	return Status{
		BackendState: raw.BackendState,
		Hostname:     raw.Self.HostName,
		TailscaleIPs: raw.Self.TailscaleIPs,
	}, nil
}

func redactAuthKey(err error, key string) error {
	if err == nil || key == "" {
		return err
	}
	msg := strings.ReplaceAll(err.Error(), key, "tskey-REDACTED")
	return errors.New(msg)
}
```

- [ ] **Step 4: Run tests, expect PASS**

Run: `cd /Users/gintini/s/vm-claw && go test ./internal/tailscale/ -v`
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/tailscale/
git commit -m "tailscale: add install/up/status wrappers over Executor"
```

### Task A10: Add `internal/cli/tailscale.go`

The `vmclaw vm tailscale-bootstrap` Cobra command.

**Files:**
- Create: `internal/cli/tailscale.go`
- Create: `internal/cli/tailscale_test.go`
- Modify: `internal/cli/vm.go` (register the subcommand)

- [ ] **Step 1: Write failing test**

Create `internal/cli/tailscale_test.go`:

```go
package cli

import (
	"bytes"
	"strings"
	"testing"
)

func TestTailscaleBootstrap_NoAuthKey_Usage(t *testing.T) {
	cmd := newTailscaleBootstrapCmd()
	buf := &bytes.Buffer{}
	cmd.SetOut(buf)
	cmd.SetErr(buf)
	cmd.SetArgs([]string{})
	err := cmd.Execute()
	if err == nil {
		t.Fatalf("expected error when no auth key provided")
	}
	if !strings.Contains(err.Error(), "auth-key") {
		t.Fatalf("expected auth-key in error, got: %v", err)
	}
}

func TestTailscaleBootstrap_AuthKeyFile_Reads(t *testing.T) {
	t.TempDir() // unused but documents the pattern
	// Just verify the flag parses; full integration is exercised in Phase C.
	cmd := newTailscaleBootstrapCmd()
	if f := cmd.Flag("auth-key-file"); f == nil {
		t.Fatal("expected --auth-key-file flag")
	}
	if f := cmd.Flag("auth-key"); f == nil {
		t.Fatal("expected --auth-key flag")
	}
}
```

- [ ] **Step 2: Run tests, expect FAIL**

Run: `cd /Users/gintini/s/vm-claw && go test ./internal/cli/ -run TestTailscaleBootstrap -v`
Expected: compile error — `newTailscaleBootstrapCmd` undefined.

- [ ] **Step 3: Implement**

Create `internal/cli/tailscale.go`:

```go
package cli

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/intinig/vm-claw/internal/tailscale"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
)

func newTailscaleBootstrapCmd() *cobra.Command {
	var authKey, authKeyFile, tag string
	cmd := &cobra.Command{
		Use:   "tailscale-bootstrap",
		Short: "Install Tailscale inside the VM and run `tailscale up`",
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx, cancel := context.WithTimeout(cmd.Context(), 5*time.Minute)
			defer cancel()

			key, err := resolveAuthKey(authKey, authKeyFile)
			if err != nil {
				return err
			}

			t := vm.NewTart()
			vmName := envOr("VM_CLAW_VM_NAME", "vm-claw")

			// Build an Executor that shells out via `tart exec` inside the VM.
			inVM := tartExecExecutor{tart: t, vmName: vmName}

			fmt.Fprintln(cmd.OutOrStdout(), "Installing tailscale-app cask inside VM...")
			if err := tailscale.Install(ctx, inVM); err != nil {
				return err
			}
			fmt.Fprintln(cmd.OutOrStdout(), "Running tailscale up...")
			if err := tailscale.Up(ctx, inVM, key, tag); err != nil {
				return err
			}
			s, err := tailscale.Status(ctx, inVM)
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Tailscale state=%s host=%s ips=%v\n", s.BackendState, s.Hostname, s.TailscaleIPs)

			fmt.Fprintln(cmd.OutOrStdout(), "Enabling firewall block-all-incoming...")
			if err := vm.EnableBlockAllIncoming(ctx, inVM); err != nil {
				return err
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&authKey, "auth-key", "", "Tailscale auth key (tskey-...). Mutually exclusive with --auth-key-file.")
	cmd.Flags().StringVar(&authKeyFile, "auth-key-file", "", "Path to a file containing the auth key (file is read once).")
	cmd.Flags().StringVar(&tag, "tag", "tag:vm-claw", "Tailscale advertise tag for this VM.")
	return cmd
}

func resolveAuthKey(flagVal, filePath string) (string, error) {
	if flagVal != "" && filePath != "" {
		return "", fmt.Errorf("--auth-key and --auth-key-file are mutually exclusive")
	}
	if flagVal != "" {
		return flagVal, nil
	}
	if filePath != "" {
		body, err := os.ReadFile(filePath)
		if err != nil {
			return "", fmt.Errorf("read auth-key-file: %w", err)
		}
		return strings.TrimSpace(string(body)), nil
	}
	return "", fmt.Errorf("--auth-key or --auth-key-file is required")
}

// tartExecExecutor implements vm.Executor by shelling out via `tart exec`.
type tartExecExecutor struct {
	tart   *vm.Tart
	vmName string
}

func (e tartExecExecutor) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	full := append([]string{"exec", e.vmName, "--", name}, args...)
	return vm.DefaultExecutor.Run(ctx, "tart", full...)
}
```

- [ ] **Step 4: Register the subcommand under `vmclaw vm`**

Edit `internal/cli/vm.go`. Inside the `init()` that builds the `vm` parent command, add:

```go
vmCmd.AddCommand(newTailscaleBootstrapCmd())
```

(Replace `vmCmd` with the actual local variable name in the existing init.)

- [ ] **Step 5: Run tests + build**

Run: `cd /Users/gintini/s/vm-claw && go test ./internal/cli/ -v && go build ./...`
Expected: all PASS, clean build.

- [ ] **Step 6: Commit**

```bash
git add internal/cli/tailscale.go internal/cli/tailscale_test.go internal/cli/vm.go
git commit -m "cli: add 'vmclaw vm tailscale-bootstrap' command"
```

### Task A11: Update `internal/cli/vm.go` defaults to Sequoia naming

VM name `bridge-vm` → `vm-claw` everywhere as a default. Old name still accepted via env var for any in-place migration.

**Files:**
- Modify: `internal/cli/vm.go`

- [ ] **Step 1: Read vm.go in full**

Read `/Users/gintini/s/vm-claw/internal/cli/vm.go`.

- [ ] **Step 2: Replace `bridge-vm` default with `vm-claw`**

Use `Edit` with `replace_all: true` only after confirming the only `bridge-vm` occurrence is the intended default. If there are other refs (e.g., in usage strings), update accordingly.

Verify with: `cd /Users/gintini/s/vm-claw && grep -n bridge-vm internal/cli/vm.go`. After the edit, this should return zero hits.

- [ ] **Step 3: Build + test**

Run: `cd /Users/gintini/s/vm-claw && go build ./... && go test ./...`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add internal/cli/vm.go
git commit -m "cli/vm: default VM name to vm-claw"
```

### Task A12: Author the OpenClaw config sample

**Files:**
- Create: `docs/openclaw-config.example.yaml`

- [ ] **Step 1: Write the sample**

Create `docs/openclaw-config.example.yaml`:

```yaml
# Sample OpenClaw config — copy to ~/.openclaw/config.yaml inside the vm-claw VM.
# This file encodes the security contract documented in
# docs/superpowers/specs/2026-05-25-openclaw-sequoia-vm-design.md (Security Surface Mapping).

# --- Auth + permissions (do not weaken) ---
auth:
  required: true            # WebChat / API auth token required, even on the tailnet.

permissions:
  askConfirmation: true     # All sensitive actions require user confirmation.

terminal:
  persistent: false         # Ephemeral sandbox — no state leaks across invocations.
  # No workspaceMount: do not bind-mount host paths into the agent's terminal.

# --- Plugin allowlist (mitigates ClawHavoc-class supply chain) ---
plugins:
  allowList:
    - openclaw/policy        # Bundled policy plugin (channel conformance checks).
    - openclaw/imessage      # iMessage channel — required.
    # Add specific plugins by exact name. No wildcards. No auto-install.
  autoInstall: false

# --- iMessage channel (imsg-backed) ---
channels:
  imessage:
    enabled: true
    cliPath: imsg            # brew-installed at /opt/homebrew/bin/imsg
    dmPolicy: allowlist
    allowFrom:
      - "+1XXXXXXXXXX"       # Your own iMessage handle (replace placeholder).
    groupPolicy: allowlist
    groupAllowFrom: []       # Add chat_guid or chat_identifier entries to allow group inputs.
    groups:
      "*":
        requireMention: true # Bot only replies when @-mentioned (Apple inline mention or pattern).

# --- Agent group-chat mention patterns ---
agents:
  list:
    - name: default
      groupChat:
        mentionPatterns:
          - "^@?openclaw\\b"
          - "^@?claw\\b"

# --- Provider keys (chmod 600 the whole config.yaml) ---
providers:
  anthropic:
    apiKey: REPLACE_FROM_BACKUP_ENV
  openai:
    apiKey: REPLACE_FROM_BACKUP_ENV

# --- WebChat binding (Tailscale-only inbound) ---
webchat:
  host: 127.0.0.1            # Bind to loopback; Tailscale Serve forwards from tailnet.
  port: 18789

# --- Gateway logging ---
gateway:
  logLevel: info
```

- [ ] **Step 2: Commit**

```bash
git add docs/openclaw-config.example.yaml
git commit -m "docs: add OpenClaw config sample encoding the security contract"
```

### Task A13: Write the manual runbook `docs/runbook-openclaw-install.md`

**Files:**
- Create: `docs/runbook-openclaw-install.md`

- [ ] **Step 1: Write the runbook**

Create `docs/runbook-openclaw-install.md`:

````markdown
# OpenClaw install runbook (inside the vm-claw VM)

Pre-conditions:
- `vmclaw bootstrap` completed; VM is up.
- Apple ID signed into Messages.app inside the VM GUI; iMessage active.
- `vmclaw vm tailscale-bootstrap` completed; VM has joined the tailnet.
- You have the Tailscale name of the VM (e.g. `vm-claw.tail-abcdef.ts.net`).

## Steps

### 1) SSH into the VM via tailnet

```bash
tailscale ssh <bridge-user>@vm-claw.tail-abcdef.ts.net
```

If you used `--ssh` during `tailscale up` (default in this project), no extra SSH keys are needed — Tailscale brokers the auth.

### 2) Install Node 24 LTS

```bash
brew install node@24
brew link --overwrite node@24
node -v   # expect v24.x
```

### 3) Install OpenClaw (latest stable)

```bash
npm install -g openclaw@latest
openclaw --version
```

### 4) Install `imsg`

```bash
brew install steipete/tap/imsg
imsg --help
```

Grant Full Disk Access to `imsg` and to `node` (the openclaw gateway runtime):
- System Settings → Privacy & Security → Full Disk Access → add `/opt/homebrew/bin/imsg` AND `/opt/homebrew/bin/node` (the brew node 24 binary).
- Required because both processes need to read `~/Library/Messages/chat.db`.

### 5) Set up OpenClaw config

```bash
mkdir -p ~/.openclaw
cp /path/from/repo/docs/openclaw-config.example.yaml ~/.openclaw/config.yaml
chmod 600 ~/.openclaw/config.yaml
```

Edit `~/.openclaw/config.yaml`:
- Replace `REPLACE_FROM_BACKUP_ENV` with your real provider API keys (from `~/Documents/vmclaw-backup.env` on the host — `scp` it over the tailnet).
- Replace the placeholder `+1XXXXXXXXXX` in `channels.imessage.allowFrom` with your own iMessage handle.

### 6) Install the OpenClaw gateway as a LaunchAgent

```bash
openclaw onboard --install-daemon
```

This writes `~/Library/LaunchAgents/ai.openclaw.gateway.plist` and loads it. Verify:

```bash
launchctl print gui/$(id -u)/ai.openclaw.gateway | head -20
openclaw status
```

### 7) Verify iMessage channel

```bash
openclaw channels status --probe --channel imessage
```

Expected: `imessage: ok` with imsg binary path printed.

### 8) Apply Tailscale Serve for WebChat (optional)

If you want OpenClaw WebChat reachable from your host browser at `http://vm-claw.tail-abcdef.ts.net`:

```bash
sudo tailscale serve --bg --https=443 http://127.0.0.1:18789
```

### 9) From the host, run doctor

```bash
vmclaw doctor
```

Expected: green across the chain.

### 10) Smoke test

From another Apple device signed into a different Apple ID, send an iMessage to the bridge Apple ID:

> @openclaw what's the weather?

Expected: OpenClaw replies within ~5 seconds.
````

- [ ] **Step 2: Commit**

```bash
git add docs/runbook-openclaw-install.md
git commit -m "docs: add OpenClaw install runbook for inside-VM manual steps"
```

### Task A14: Rewrite CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` (full rewrite)

- [ ] **Step 1: Read the current CLAUDE.md once more for any keepers**

Read `/Users/gintini/s/vm-claw/CLAUDE.md`. Identify reusable sections (Tart commands ref, Tahoe vmnet workaround block, recovery list pattern).

- [ ] **Step 2: Replace contents**

Replace CLAUDE.md with this (full content):

````markdown
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
- `internal/vm/` — Tart wrapper, vmnet collision detection, bridge-interface detection, brew helpers, macOS Application Firewall wrapper.
- `internal/tailscale/` — Tailscale install/up/status wrappers over a `vm.Executor` (so they work via `tart exec` inside the VM).
- `internal/launchagent/` — host-side LaunchAgent that auto-starts the VM at login.
- `internal/doctor/` — chain-walking doctor checks.
- `docs/openclaw-config.example.yaml` — canonical OpenClaw config template.
- `docs/runbook-openclaw-install.md` — manual steps to install OpenClaw inside the VM.
- `docs/superpowers/specs/2026-05-25-openclaw-sequoia-vm-design.md` — authoritative spec.
````

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "Rewrite CLAUDE.md for OpenClaw-on-Sequoia scope"
```

### Task A15: Rewrite README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace contents**

Use the structure proposed in spec Section 6 (README), adapted to current resolved facts:

````markdown
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
````

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Rewrite README for OpenClaw-on-Sequoia scope"
```

### Task A16: Build, test, push branch, open PR

**Files:** none (verification + git).

- [ ] **Step 1: Final build + tests**

Run: `cd /Users/gintini/s/vm-claw && go build ./... && go test ./...`
Expected: clean build, all tests pass.

- [ ] **Step 2: `go mod tidy`**

Run: `cd /Users/gintini/s/vm-claw && go mod tidy && git diff --stat go.mod go.sum`
Expected: minimal diff (any unused imports cleaned up).

- [ ] **Step 3: Commit any mod tidy changes**

```bash
git add go.mod go.sum
git commit -m "go mod tidy after Hermes removal" || true
```

- [ ] **Step 4: Push the branch**

```bash
git push -u origin rescope-openclaw-sequoia
```

- [ ] **Step 5: Open PR**

```bash
gh pr create --title "Rescope: OpenClaw-on-Sequoia VM (supersedes Hermes/Tahoe bridge)" --body "$(cat <<'EOF'
## Summary

- Drops Hermes-on-host + Tahoe bridge-vm model entirely.
- VM now runs OpenClaw + Messages.app + Tailscale on macOS Sequoia 15.x.
- New `vmclaw vm tailscale-bootstrap` installs Tailscale + macOS firewall lockdown inside the VM.
- New doctor check set (20 checks covering host, VM lifecycle, inside-VM state, negative-connectivity boundary proofs, outbound liveness).
- OpenClaw install itself is a manual runbook (`docs/runbook-openclaw-install.md`); vmclaw stops at "VM ready for OpenClaw."

## Spec
docs/superpowers/specs/2026-05-25-openclaw-sequoia-vm-design.md

## Test plan
- [ ] make test passes
- [ ] Phase B (destructive cleanup) succeeds; ~64 GB reclaimed
- [ ] Phase C (rebuild) gets vmclaw doctor green
- [ ] End-to-end iMessage smoke test passes

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

PR opens; do NOT merge yet. Phase B and C must complete first.

---

## Phase B — Destructive Host Cleanup

Irreversible. Backup first. Each step has a verification.

### Task B1: Back up provider API keys

**Files:**
- Create: `~/Documents/vmclaw-backup.env`

- [ ] **Step 1: Verify source exists**

```bash
ls -la ~/.hermes/.env 2>&1
```

Expected: file exists with `-rw-------` permissions. If missing, skip the rest of Phase B — there's nothing left to back up and the user can grab provider keys from their password manager.

- [ ] **Step 2: Copy and lock down**

```bash
mkdir -p ~/Documents
cp ~/.hermes/.env ~/Documents/vmclaw-backup.env
chmod 600 ~/Documents/vmclaw-backup.env
ls -la ~/Documents/vmclaw-backup.env
```

Expected: file exists, `-rw-------`.

- [ ] **Step 3: Visual verify content (no secrets in shell history)**

Open in a text editor (TextEdit / your IDE) and confirm the API keys are present. Do NOT cat or echo to terminal.

### Task B2: Destroy the existing Tahoe VM

- [ ] **Step 1: List VMs and base images**

```bash
tart list
```

Expected output similar to:
```
local  bridge-vm                                              50  35  ...  stopped
OCI    ghcr.io/cirruslabs/macos-tahoe-base:latest             50  32  ...  stopped
OCI    ghcr.io/cirruslabs/macos-tahoe-base@sha256:f883f1...   50  32  ...  stopped
```

- [ ] **Step 2: Stop and delete `bridge-vm`**

```bash
tart stop bridge-vm 2>&1 || true
tart delete bridge-vm
```

Expected: no error.

- [ ] **Step 3: Delete the Tahoe base images**

```bash
tart delete ghcr.io/cirruslabs/macos-tahoe-base:latest
tart delete ghcr.io/cirruslabs/macos-tahoe-base@sha256:f883f13f3f076ee2aa97f92a7341801f83655037dcfecd184872574d5664cbde
```

Expected: no error. (The digest is from the earlier `tart list` output.)

- [ ] **Step 4: Verify**

```bash
tart list && du -sh ~/.tart 2>&1
```

Expected: empty `tart list` (or only base images you intentionally kept); `~/.tart` size dropped from ~64 GB to <1 GB.

### Task B3: Remove the old LaunchAgent

- [ ] **Step 1: Identify the old plist**

```bash
ls ~/Library/LaunchAgents/ | grep -E 'vm-claw|bridge'
```

Expected: one or more files like `com.vm-claw.bridge-vm.plist`.

- [ ] **Step 2: Bootout and remove**

For each matching plist:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.vm-claw.bridge-vm.plist 2>&1 || true
rm ~/Library/LaunchAgents/com.vm-claw.bridge-vm.plist
```

- [ ] **Step 3: Verify**

```bash
ls ~/Library/LaunchAgents/ | grep -E 'vm-claw|bridge' || echo "clean"
launchctl print gui/$(id -u) 2>&1 | grep vm-claw || echo "no vm-claw services"
```

Expected: `clean` and `no vm-claw services`.

### Task B4: Remove Colima

- [ ] **Step 1: Stop and delete the colima profile**

```bash
colima stop 2>&1 || true
colima delete --force 2>&1 || true
```

Expected: profile removed (or "profile not found" if already gone).

- [ ] **Step 2: Remove the data dir**

```bash
rm -rf ~/.colima
ls ~/.colima 2>&1 || echo "gone"
```

Expected: `gone`.

- [ ] **Step 3: Uninstall the brew formula**

```bash
brew uninstall colima 2>&1 || true
which colima 2>&1 || echo "colima not on PATH"
```

Expected: `colima not on PATH`.

### Task B5: Remove Docker

- [ ] **Step 1: Uninstall docker CLI**

```bash
brew uninstall docker 2>&1 || true
which docker 2>&1 || echo "docker not on PATH"
```

Expected: `docker not on PATH`.

- [ ] **Step 2: Remove docker state**

```bash
rm -rf ~/.docker
ls ~/.docker 2>&1 || echo "gone"
```

Expected: `gone`.

### Task B6: Remove `~/.hermes`

- [ ] **Step 1: Final check that backup exists**

```bash
ls -la ~/Documents/vmclaw-backup.env
```

Expected: file exists, chmod 600.

- [ ] **Step 2: Remove `~/.hermes`**

```bash
rm -rf ~/.hermes
ls ~/.hermes 2>&1 || echo "gone"
```

Expected: `gone`.

### Task B7: Verify disk reclaim

- [ ] **Step 1: Compare reclaim**

```bash
du -sh ~/.tart ~/.colima ~/.hermes ~/.docker 2>&1
df -h /
```

Expected: each of the four paths is missing or empty; free disk space should have grown by approximately 64–98 GB.

- [ ] **Step 2: Smoke-check `vmclaw doctor` (will be red — expected)**

```bash
vmclaw doctor
```

Expected: most checks red — there's no VM, no LaunchAgent, no Tailscale on host yet. This is the baseline before Phase C.

---

## Phase C — Rebuild on Sequoia

### Task C1: Ensure Tailscale is installed on the host

- [ ] **Step 1: Check**

```bash
which tailscale || echo missing
```

- [ ] **Step 2: Install if missing**

```bash
brew install --cask tailscale-app
open -a Tailscale  # opens GUI; sign in if you haven't, approve system extension
```

Expected: Tailscale menu-bar icon appears; `tailscale status` works in a new terminal.

- [ ] **Step 3: Verify tailnet name**

```bash
tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"])'
```

Expected: prints your host's tailnet DNS name (e.g. `mymac.tail-abcdef.ts.net`). This confirms the tailnet exists.

### Task C2: Create the Sequoia VM

- [ ] **Step 1: Bootstrap**

```bash
cd /Users/gintini/s/vm-claw
make install
vmclaw bootstrap
```

Expected:
- Tart pulls `ghcr.io/cirruslabs/macos-sequoia-base@sha256:<digest>` (~30–60 min first time).
- VM clones to `vm-claw`.
- LaunchAgent `com.vm-claw.agent.plist` installed and loaded.
- VM starts; bridged IP printed.
- "Next steps (manual)" runbook printed.

- [ ] **Step 2: Verify**

```bash
tart list
tart ip vm-claw
launchctl print gui/$(id -u)/com.vm-claw.agent | head -10
```

Expected: VM listed, IP returned, LaunchAgent state `running`.

### Task C3: GUI: sign Apple ID into Messages.app

Open the Tart VM window (it should appear on first run; if not, `tart run vm-claw --gui &` from another terminal).

- [ ] **Step 1: Complete macOS first-boot wizard**

The Cirrus Sequoia base image boots into Setup Assistant. Choose a region, language, etc. Set up a local user account (this is the "bridge user").

- [ ] **Step 2: Sign into the bridge Apple ID**

System Settings → Apple ID → Sign In. Use the SAME Apple ID you used on the old Tahoe bridge-vm. Complete 2FA. Apple may prompt "Trust this Mac" — confirm.

- [ ] **Step 3: Enable iMessage**

Open Messages.app → Settings → iMessage → Sign In with the same Apple ID. Verify your phone/email handles are checked under "You can be reached for messages at." Set "Start new conversations from" to whichever you prefer.

- [ ] **Step 4: Disable sleep**

System Settings → Lock Screen → Start Screen Saver when inactive: Never. Display sleep when on power: Never. Battery → Power Adapter → Prevent automatic sleeping: On.

- [ ] **Step 5: Enable auto-login**

System Settings → Users & Groups → Automatic login: select the bridge user. (May require disabling FileVault first; Cirrus base images ship with FileVault off so this should just work.)

### Task C4: Run `vmclaw vm tailscale-bootstrap`

- [ ] **Step 1: Get a Tailscale auth key**

In your browser: Tailscale admin → Keys → Generate auth key. Use settings: reusable=OFF, ephemeral=OFF, pre-approved=ON, tags=`tag:vm-claw`. Copy the `tskey-auth-...` value.

(Configure `tag:vm-claw` in your tailnet ACL first if it doesn't exist:
```jsonc
{
  "tagOwners": { "tag:vm-claw": ["autogroup:owner"] },
  "acls": [
    { "action": "accept", "src": ["<your-user-or-tagged-devices>"], "dst": ["tag:vm-claw:*"] }
  ]
}
```
)

- [ ] **Step 2: Run tailscale-bootstrap**

```bash
echo 'tskey-auth-...' > /tmp/ts.key && chmod 600 /tmp/ts.key
vmclaw vm tailscale-bootstrap --auth-key-file=/tmp/ts.key
rm /tmp/ts.key
```

Expected:
- "Installing tailscale-app cask inside VM..." (~2–3 min)
- "Running tailscale up..."
- "Tailscale state=Running host=vm-claw ips=[100.x.x.x]"
- "Enabling firewall block-all-incoming..."
- No errors.

- [ ] **Step 3: GUI approval (if first install)**

Inside the VM, System Settings → Network → Filters. If a Tailscale extension is pending approval, click Allow. Then back in the host terminal:

```bash
tart exec vm-claw -- tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["BackendState"])'
```

Expected: `Running`.

### Task C5: From host, SSH into VM via tailnet

- [ ] **Step 1: Confirm tailnet name**

```bash
tart exec vm-claw -- tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"])'
```

Expected: e.g. `vm-claw.tail-abcdef.ts.net.`

- [ ] **Step 2: SSH in**

```bash
tailscale ssh <bridge-user>@vm-claw.tail-abcdef.ts.net
```

Expected: shell prompt in the VM. Confirm with `sw_vers -productVersion` (should show 15.x).

### Task C6: Inside VM — follow the OpenClaw runbook

Steps from `docs/runbook-openclaw-install.md`. Each is a checkpoint.

- [ ] **C6.1: Install Node 24**

```bash
brew install node@24 && brew link --overwrite node@24 && node -v
```

Expected: `v24.x`.

- [ ] **C6.2: Install OpenClaw**

```bash
npm install -g openclaw@latest && openclaw --version
```

Expected: a version like `2026.5.22`.

- [ ] **C6.3: Install imsg**

```bash
brew install steipete/tap/imsg && imsg --help
```

Expected: help text printed.

- [ ] **C6.4: Grant Full Disk Access**

GUI: System Settings → Privacy & Security → Full Disk Access → add `/opt/homebrew/bin/imsg` and `/opt/homebrew/bin/node`. Restart Messages.app and the SSH session for the permissions to take effect.

- [ ] **C6.5: Copy provider keys to OpenClaw config**

From the host, copy the backup to the VM via Tailscale SCP:

```bash
scp -o ProxyCommand="tailscale nc %h %p" ~/Documents/vmclaw-backup.env <bridge-user>@vm-claw.tail-abcdef.ts.net:/tmp/vmclaw-backup.env
```

Or use the tailscale-aware shortcut:

```bash
tailscale file cp ~/Documents/vmclaw-backup.env vm-claw:
```

Inside the VM:

```bash
mkdir -p ~/.openclaw
cp /path/to/repo/docs/openclaw-config.example.yaml ~/.openclaw/config.yaml
# Or curl from a clone of the repo inside the VM.
chmod 600 ~/.openclaw/config.yaml
```

Edit `~/.openclaw/config.yaml`: replace `REPLACE_FROM_BACKUP_ENV` with the values from `/tmp/vmclaw-backup.env`, and replace the `+1XXXXXXXXXX` placeholder with your iMessage handle.

```bash
rm /tmp/vmclaw-backup.env  # secure-delete the temp copy
```

- [ ] **C6.6: Install OpenClaw gateway LaunchAgent**

```bash
openclaw onboard --install-daemon
launchctl print gui/$(id -u)/ai.openclaw.gateway | head -10
```

Expected: LaunchAgent state `running`.

- [ ] **C6.7: Probe iMessage channel**

```bash
openclaw channels status --probe --channel imessage
```

Expected: `imessage: ok`.

### Task C7: Run `vmclaw doctor`

- [ ] **Step 1: Run from host**

```bash
vmclaw doctor
```

Expected: all 19 (non-smoke) checks green or expected-yellow. Specifically:
- `bridged-port-unreachable`: GREEN (firewall is blocking).
- `tailnet-port-reachable`: GREEN.
- `vm-outbound-works`: GREEN.

Yellow is acceptable for `vm-openclaw-version-not-fresh` (depends on when the upstream release was promoted).

- [ ] **Step 2: Resolve any red**

If anything is red, drop down to that check's recovery path in CLAUDE.md. Re-run doctor.

### Task C8: End-to-end smoke test

- [ ] **Step 1: From another Apple device** (your phone, signed into your personal Apple ID — NOT the bridge one) send an iMessage to the bridge Apple ID:

```
@openclaw what time is it?
```

Expected: a reply from OpenClaw within ~10 seconds.

- [ ] **Step 2: From the host, run finalize**

```bash
vmclaw bootstrap finalize
```

Expected: doctor + smoke pass.

### Task C9: Merge the PR

- [ ] **Step 1: Final push (any post-rebuild fixups)**

```bash
cd /Users/gintini/s/vm-claw
git status
# Commit anything that drifted (likely nothing).
git push
```

- [ ] **Step 2: Merge**

Via `gh`:

```bash
gh pr merge rescope-openclaw-sequoia --merge --delete-branch
```

Or in the GitHub UI. Squash is fine; merge-commit is also fine. After merge:

```bash
git checkout main
git pull
git branch -d rescope-openclaw-sequoia 2>&1 || true
```

- [ ] **Step 3: Final doctor run from main**

```bash
make install
vmclaw doctor
```

Expected: still green.

---

## Self-Review (already performed by the planner — listed for record)

**Spec coverage:** every section of the spec has at least one task:
- Architecture → Tasks A1–A11 (code) + A14, A15 (docs).
- Components → File Structure section above, executed via A1–A11.
- Security Surface Mapping → Tasks A7 (doctor checks), A8 (firewall), A12 (config sample).
- Network Posture → Task A8 (firewall) + A9 (Tailscale) + A10 (CLI command) + doctor #18 negative connectivity.
- CLI Surface → Tasks A4, A10, A11.
- Doctor Checks → Task A7.
- Cleanup + Rebuild Sequencing → Phases B and C.
- Decisions → Encoded throughout; version=latest in A12; VM name `vm-claw` in A6, A11; branch strategy executed; `~/.hermes` cleanup in B6.
- Risks → addressed via doctor checks (A7) and config defaults (A12).
- Open Implementation Questions → all six resolved in the header of this plan.

**Placeholder scan:** no "TBD" / "implement later" left. The single `TODO(smoke)` in `internal/doctor/checks.go` is intentional — it gates a feature (live iMessage round-trip) that requires an external Apple device and so cannot be unit-tested.

**Type consistency:** `Options.VMName` (launchagent) used consistently in A6, A4. `vm.Executor` used consistently in A2, A8, A9. `tailscale.Status{BackendState, Hostname, TailscaleIPs}` matches between A9 implementation and A10 consumption.
