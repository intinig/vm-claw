# vmclaw CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the four bash scripts (`setup.sh`, `run.sh`, `destroy.sh`, `hermes-setup.sh`) and the planned auto-start LaunchAgent + healthcheck helpers with a single Go binary, `vmclaw`, that owns Tart VM lifecycle, Colima/Docker bootstrap, BlueBubbles webhook secret generation, Hermes `.env` wiring, and end-to-end healthchecks.

**Architecture:** Go binary built with [Cobra](https://github.com/spf13/cobra). Cobra command handlers in `internal/cli/` translate flags into calls to domain packages under `internal/{vm,hermes,launchagent,doctor}/`, which shell out to external tools (`tart`, `colima`, `docker`, `brew`, `softnet`, `launchctl`) via a small testable `Executor` interface. Two-phase bootstrap: `vmclaw bootstrap` runs all automatable pre-Phase-2 steps; `vmclaw bootstrap finalize` runs all post-Phase-2 wiring + healthcheck. Webhook secret auto-generated once and reused forever.

**Tech Stack:** Go 1.22+, [`spf13/cobra`](https://github.com/spf13/cobra), [`golang.org/x/term`](https://pkg.go.dev/golang.org/x/term) (masked password input), `crypto/rand`, `text/template`, `embed`. Standard `go test` + `//go:build integration` tag for integration tests.

**Spec:** [`docs/superpowers/specs/2026-05-04-vmclaw-cli-design.md`](../specs/2026-05-04-vmclaw-cli-design.md) (committed `f0c8946`).

**Repo state at plan start:** branch `main`, latest commit `f0c8946`. Working tree clean. Four bash scripts (`setup.sh`, `run.sh`, `destroy.sh`, `hermes-setup.sh`) exist and are committed; this plan deletes them in Phase G.

## Phase map

- **Phase A** — Project scaffolding (3 tasks). End state: `make build && ./bin/vmclaw --version` works.
- **Phase B** — `internal/vm` package (2 tasks). Tart wrappers + vmnet collision check.
- **Phase C** — `internal/hermes` package (4 tasks). Webhook secret, env file, Colima, Docker.
- **Phase D** — `internal/launchagent` package (1 task). Plist render + install/uninstall.
- **Phase E** — `internal/doctor` package (1 task). End-to-end healthcheck rows.
- **Phase F** — Cobra command handlers in `internal/cli/` (4 tasks). One file per namespace.
- **Phase G** — Cleanup & documentation (3 tasks). Delete bash scripts, update CLAUDE.md / README.md, append "superseded" notes to prior spec/plan.
- **Phase H** — Deferred manual research (1 documentation-only callout).

**Total: 18 tasks.** Plan is sequenced so each task ends with a working build and passing tests.

---

## Phase A — Project scaffolding

### Task A.1: Initialize Go module, Makefile, .gitignore

**Files:**
- Create: `go.mod`
- Create: `Makefile`
- Modify: `.gitignore` (create if absent)

- [ ] **Step 1: Initialize the Go module**

```bash
cd /Users/gintini/s/vm-claw
go mod init github.com/intinig/vm-claw
```

Expected: `go: creating new go.mod: module github.com/intinig/vm-claw`. Creates `go.mod` with `go 1.22` (or whatever your local Go version is).

- [ ] **Step 2: Pin minimum Go version explicitly**

Edit `go.mod` so the `go` directive line reads `go 1.22`. If your local Go is newer, leave `toolchain go1.<x>` lines alone. The `go.mod` should look like:

```
module github.com/intinig/vm-claw

go 1.22
```

- [ ] **Step 3: Write the Makefile**

Path: `/Users/gintini/s/vm-claw/Makefile`

```make
# vmclaw build / install
BIN_NAME := vmclaw
BIN_DIR  := bin
PKG      := ./cmd/vmclaw

GIT_SHA     := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
VERSION     := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
LDFLAGS     := -ldflags "-X main.version=$(VERSION)+$(GIT_SHA)"

.PHONY: all build install uninstall test integration clean

all: build

build:
	@mkdir -p $(BIN_DIR)
	go build $(LDFLAGS) -o $(BIN_DIR)/$(BIN_NAME) $(PKG)

install:
	go install $(LDFLAGS) $(PKG)

uninstall:
	rm -f $$(go env GOPATH)/bin/$(BIN_NAME)

test:
	go test ./...

integration:
	go test -tags=integration ./...

clean:
	rm -rf $(BIN_DIR)
```

- [ ] **Step 4: Update .gitignore**

If `/Users/gintini/s/vm-claw/.gitignore` exists, append the lines below. If absent, create it with these contents:

```
bin/
vmclaw
*.test
```

(`bin/` for the make-build output, bare `vmclaw` for safety in case someone runs `go build` at the repo root, `*.test` for `go test -c` artifacts.)

- [ ] **Step 5: Verify the scaffolding compiles (it won't link yet — there's no main package)**

```bash
go mod tidy && echo "go.mod tidy OK"
ls -la go.mod Makefile .gitignore
```

Expected: `go.mod tidy OK`, all three files listed.

- [ ] **Step 6: Commit**

```bash
git add go.mod Makefile .gitignore
git commit -m "$(cat <<'EOF'
Scaffold Go module for vmclaw CLI

- module github.com/intinig/vm-claw, go 1.22
- Makefile with build/install/uninstall/test/integration/clean targets
- .gitignore for bin/, vmclaw, *.test

First task of vmclaw CLI migration; cmd/vmclaw/main.go follows.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task A.2: Cobra root command + main.go + --version flag

**Files:**
- Create: `cmd/vmclaw/main.go`
- Create: `internal/cli/root.go`
- Modify: `go.mod`, `go.sum` (auto via `go get`)

- [ ] **Step 1: Add Cobra dependency**

```bash
go get github.com/spf13/cobra@latest
```

Expected: `go.mod` now has `require github.com/spf13/cobra vX.Y.Z`. `go.sum` populated.

- [ ] **Step 2: Create the CLI root**

Path: `/Users/gintini/s/vm-claw/internal/cli/root.go`

```go
// Package cli wires Cobra commands and exposes Execute as the binary entry point.
package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

// Version is set at build time via -ldflags "-X main.version=...".
// main copies the linker-injected value into this package var.
var Version = "dev"

// rootCmd is the top-level vmclaw command. Subcommand packages register
// children onto it via init() functions.
var rootCmd = &cobra.Command{
	Use:           "vmclaw",
	Short:         "Manage the Hermes + iMessage bridge VM stack",
	Long:          "vmclaw owns the Tart bridge VM, Colima/Docker host bootstrap for Hermes, and the wiring between them.",
	SilenceUsage:  true,  // don't dump help on RunE errors
	SilenceErrors: true,  // we print errors ourselves
	Version:       Version,
}

// Execute runs the root command. Returns the process exit code.
func Execute() int {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %s\n", err.Error())
		return 1
	}
	return 0
}

// SetVersion lets main inject the linker-built version after init.
// Called once from cmd/vmclaw/main.go before Execute().
func SetVersion(v string) {
	Version = v
	rootCmd.Version = v
}

// rootCommand is exported for subcommand packages to register children on.
// Internal use only — not part of any public API.
func RootCommand() *cobra.Command {
	return rootCmd
}
```

- [ ] **Step 3: Create the entrypoint**

Path: `/Users/gintini/s/vm-claw/cmd/vmclaw/main.go`

```go
// Package main is the vmclaw entrypoint. Build with:
//
//	go build -ldflags "-X main.version=$(git describe --tags --always)+$(git rev-parse --short HEAD)" ./cmd/vmclaw
//
// or use the project Makefile.
package main

import (
	"os"

	"github.com/intinig/vm-claw/internal/cli"
)

// version is overridden at build time via -ldflags. Default "dev" for
// local `go run`/`go build` without ldflags.
var version = "dev"

func main() {
	cli.SetVersion(version)
	os.Exit(cli.Execute())
}
```

- [ ] **Step 4: Build + smoke test**

```bash
go mod tidy
make build
./bin/vmclaw --version
./bin/vmclaw --help
```

Expected:
- `go mod tidy` runs clean (cobra + transitive deps resolved).
- `make build` produces `./bin/vmclaw` (an Apple Silicon Mach-O binary).
- `./bin/vmclaw --version` prints `vmclaw <something>+<sha>` (the `version` line populated by ldflags).
- `./bin/vmclaw --help` prints Cobra-default help with no subcommands listed yet (none are registered).

- [ ] **Step 5: Commit**

```bash
git add go.mod go.sum cmd/vmclaw/main.go internal/cli/root.go
git commit -m "$(cat <<'EOF'
Add Cobra root command and main entrypoint

- cmd/vmclaw/main.go injects -ldflags version into internal/cli.
- internal/cli/root.go exposes the rootCmd, Execute(), and a
  RootCommand() accessor for subcommand packages to register on.
- go.mod / go.sum populated with spf13/cobra.

Subcommand packages (vm, hermes, doctor, bootstrap) follow.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task A.3: Verify CLI scaffold

**Files:** none (read-only verification).

This task is a checkpoint, not a code change. Catches scaffolding regressions before subcommand packages start landing.

- [ ] **Step 1: Build, run version, run help**

```bash
make clean && make build
./bin/vmclaw --version
./bin/vmclaw --help
./bin/vmclaw          # no subcommand — should print help and exit 0
echo "EXIT: $?"
```

Expected: build succeeds, `--version` prints `vmclaw <ver>+<sha>`, `--help` prints help text with no subcommands. Bare `./bin/vmclaw` prints help and exits 0 (Cobra's default for a root command without `Run`).

- [ ] **Step 2: Run tests (none yet, but verify the test runner works)**

```bash
make test
```

Expected: `ok    github.com/intinig/vm-claw/internal/cli   [no test files]` or similar. Exit 0.

- [ ] **Step 3: No commit. Phase A complete.**

---

## Phase B — internal/vm package

### Task B.1: vmnet collision check (TDD)

**Files:**
- Create: `internal/vm/vmnet.go`
- Create: `internal/vm/vmnet_test.go`

This is the highest-leverage TDD candidate in the codebase: pure-function logic on parsed `ifconfig` output, with branchy edge cases that bash makes painful.

- [ ] **Step 1: Write failing tests for `parseIfconfig` and `detectVmnetCollision`**

Path: `/Users/gintini/s/vm-claw/internal/vm/vmnet_test.go`

```go
package vm

import (
	"strings"
	"testing"
)

func TestParseIfconfig(t *testing.T) {
	in := `lo0: flags=8049<UP> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP> mtu 1500
	ether 00:11:22:33:44:55
	inet 192.168.1.50 netmask 0xffffff00 broadcast 192.168.1.255
bridge100: flags=8863<UP> mtu 1500
	options=63<RXCSUM,TXCSUM,TSO4,TSO6>
	ether ce:81:96:00:00:64
	Configuration:
		id 0:0:0:0:0:0 priority 0 hellotime 0 fwddelay 0
	member: vmenet0 flags=3<LEARNING,DISCOVER>
	inet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255
`

	got := parseIfconfig(strings.NewReader(in))

	want := map[string]ifaceInfo{
		"lo0":       {IPv4: "127.0.0.1", IsVmnetBridge: false},
		"en0":       {IPv4: "192.168.1.50", IsVmnetBridge: false},
		"bridge100": {IPv4: "192.168.64.1", IsVmnetBridge: true},
	}

	if len(got) != len(want) {
		t.Fatalf("expected %d interfaces, got %d: %#v", len(want), len(got), got)
	}
	for name, w := range want {
		g, ok := got[name]
		if !ok {
			t.Errorf("missing interface %q", name)
			continue
		}
		if g.IPv4 != w.IPv4 || g.IsVmnetBridge != w.IsVmnetBridge {
			t.Errorf("iface %q: got %#v want %#v", name, g, w)
		}
	}
}

func TestDetectVmnetCollision_NoCollision(t *testing.T) {
	ifaces := map[string]ifaceInfo{
		"en0":       {IPv4: "192.168.1.50"},
		"bridge100": {IPv4: "192.168.64.1", IsVmnetBridge: true},
	}
	if err := detectVmnetCollision(ifaces); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
}

func TestDetectVmnetCollision_Collision(t *testing.T) {
	// vmnet bridge subnet 192.168.64.x collides with en0 on 192.168.64.x
	ifaces := map[string]ifaceInfo{
		"en0":       {IPv4: "192.168.64.10"},
		"bridge100": {IPv4: "192.168.64.1", IsVmnetBridge: true},
	}
	err := detectVmnetCollision(ifaces)
	if err == nil {
		t.Fatal("expected collision error, got nil")
	}
	if !strings.Contains(err.Error(), "vmnet subnet collides") {
		t.Errorf("error should mention 'vmnet subnet collides', got %q", err)
	}
	if !strings.Contains(err.Error(), "en0") {
		t.Errorf("error should name the colliding interface en0, got %q", err)
	}
}

func TestDetectVmnetCollision_NoBridge(t *testing.T) {
	// No vmnet bridge present → can't detect; no error.
	ifaces := map[string]ifaceInfo{
		"en0": {IPv4: "192.168.1.50"},
	}
	if err := detectVmnetCollision(ifaces); err != nil {
		t.Fatalf("expected no error when vmnet bridge absent, got %v", err)
	}
}

func TestDetectVmnetCollision_LoopbackIgnored(t *testing.T) {
	// Loopback 127.0.0.1 should never be flagged as a collision source.
	ifaces := map[string]ifaceInfo{
		"lo0":       {IPv4: "127.0.0.1"},
		"bridge100": {IPv4: "192.168.64.1", IsVmnetBridge: true},
	}
	if err := detectVmnetCollision(ifaces); err != nil {
		t.Fatalf("loopback shouldn't cause collision, got %v", err)
	}
}
```

- [ ] **Step 2: Run tests — should fail to compile**

```bash
make test
```

Expected: build error — `parseIfconfig`, `detectVmnetCollision`, `ifaceInfo` undefined.

- [ ] **Step 3: Implement `internal/vm/vmnet.go`**

Path: `/Users/gintini/s/vm-claw/internal/vm/vmnet.go`

```go
package vm

import (
	"bufio"
	"fmt"
	"io"
	"os/exec"
	"regexp"
	"strings"
)

// ifaceInfo summarizes one interface for vmnet collision detection.
type ifaceInfo struct {
	IPv4          string // first IPv4 address, or empty
	IsVmnetBridge bool   // bridge* with a "member: vmenet*" line
}

var inetLineRE = regexp.MustCompile(`^\s+inet\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\b`)

// parseIfconfig parses the output of `ifconfig` (or `ifconfig -a`) into a
// map of interface name -> info. Only IPv4 addresses are recorded; a bridge*
// interface with a `member: vmenet*` line is flagged as the vmnet bridge.
func parseIfconfig(r io.Reader) map[string]ifaceInfo {
	out := map[string]ifaceInfo{}

	var current string
	var info ifaceInfo

	flush := func() {
		if current != "" {
			out[current] = info
		}
	}

	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "\t") && !strings.HasPrefix(line, " ") && strings.Contains(line, ":") {
			// New interface header, e.g. "bridge100: flags=...".
			flush()
			current = strings.SplitN(line, ":", 2)[0]
			info = ifaceInfo{}
			continue
		}
		if m := inetLineRE.FindStringSubmatch(line); m != nil && info.IPv4 == "" {
			info.IPv4 = m[1]
		}
		if strings.HasPrefix(current, "bridge") && strings.Contains(line, "member: vmenet") {
			info.IsVmnetBridge = true
		}
	}
	flush()
	return out
}

// detectVmnetCollision returns an error if the vmnet bridge's /24 subnet
// is also used by an active host interface (e.g. en0). When this happens
// the VM gets an IP already in use on the LAN and return traffic is
// asymmetrically routed, breaking internet from the guest.
//
// If no vmnet bridge is present in `ifaces`, returns nil — we can't
// detect a collision until vmnet is up. Loopback (127.0.0.0/8) is ignored.
func detectVmnetCollision(ifaces map[string]ifaceInfo) error {
	var vmnetIface, vmnetIP, vmnetPrefix string
	for name, info := range ifaces {
		if info.IsVmnetBridge && info.IPv4 != "" {
			vmnetIface = name
			vmnetIP = info.IPv4
			vmnetPrefix = ipPrefix24(info.IPv4)
			break
		}
	}
	if vmnetPrefix == "" {
		return nil
	}

	for name, info := range ifaces {
		if name == vmnetIface || info.IPv4 == "" {
			continue
		}
		if strings.HasPrefix(info.IPv4, "127.") {
			continue
		}
		if ipPrefix24(info.IPv4) == vmnetPrefix {
			return fmt.Errorf(
				"vmnet subnet collides with active host interface: %s (%s) vs %s (%s); "+
					"the VM would get an IP already in use on your LAN. Pick a non-overlapping "+
					"subnet for vmnet — see CLAUDE.md \"vmnet bridge collides with host LAN\"",
				name, info.IPv4, vmnetIface, vmnetIP)
		}
	}
	return nil
}

// ipPrefix24 returns the /24 prefix (e.g. "192.168.1") of an IPv4 address.
// Returns "" for empty or malformed input.
func ipPrefix24(ip string) string {
	idx := strings.LastIndex(ip, ".")
	if idx <= 0 {
		return ""
	}
	return ip[:idx]
}

// VmnetCollisionCheck runs `ifconfig -a` and returns an error if the active
// vmnet bridge subnet collides with any other host interface.
func VmnetCollisionCheck() error {
	cmd := exec.Command("ifconfig", "-a")
	out, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("ifconfig -a: %w", err)
	}
	return detectVmnetCollision(parseIfconfig(strings.NewReader(string(out))))
}
```

- [ ] **Step 4: Run tests — should pass**

```bash
make test
```

Expected: `ok    github.com/intinig/vm-claw/internal/vm` with all four `TestDetect*` and one `TestParseIfconfig` passing.

- [ ] **Step 5: Commit**

```bash
git add internal/vm/vmnet.go internal/vm/vmnet_test.go
git commit -m "$(cat <<'EOF'
Add vm.VmnetCollisionCheck (port of bash function)

Pure-function ifconfig parser + /24 subnet collision detector,
plus a VmnetCollisionCheck wrapper that shells out to `ifconfig -a`.
Five unit tests cover the no-collision, collision, no-bridge, and
loopback-ignored cases.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task B.2: Tart wrappers + Executor interface

**Files:**
- Create: `internal/vm/exec.go`
- Create: `internal/vm/tart.go`
- Create: `internal/vm/tart_test.go`

A small `Executor` interface lets the production code shell out to `tart`, but tests can swap in a fake. Keeps unit tests of the output parsers fast and offline.

- [ ] **Step 1: Write the Executor interface**

Path: `/Users/gintini/s/vm-claw/internal/vm/exec.go`

```go
package vm

import (
	"bytes"
	"context"
	"os/exec"
)

// Executor runs an external command and returns its combined stdout.
// Production code uses execShellOut; tests inject fakeExecutor.
type Executor interface {
	Run(ctx context.Context, name string, args ...string) ([]byte, error)
}

// execShellOut is the production Executor. It runs the command and returns
// captured stdout. stderr is captured into the error on non-zero exit.
type execShellOut struct{}

func (execShellOut) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return stdout.Bytes(), &execError{name: name, args: args, stderr: stderr.String(), err: err}
	}
	return stdout.Bytes(), nil
}

// execError wraps an exec failure with the captured stderr — easier to
// debug than a bare `exit status 1`.
type execError struct {
	name   string
	args   []string
	stderr string
	err    error
}

func (e *execError) Error() string {
	if e.stderr != "" {
		return e.name + ": " + e.err.Error() + ": " + e.stderr
	}
	return e.name + ": " + e.err.Error()
}

func (e *execError) Unwrap() error { return e.err }

// DefaultExecutor is the production Executor. Use this in normal code paths.
var DefaultExecutor Executor = execShellOut{}
```

- [ ] **Step 2: Write the Tart wrapper**

Path: `/Users/gintini/s/vm-claw/internal/vm/tart.go`

```go
package vm

import (
	"context"
	"fmt"
	"net"
	"strings"
)

// Tart wraps the `tart` CLI behind a typed Go interface.
// Construct via NewTart; the zero value isn't usable (Executor is nil).
type Tart struct {
	exec Executor
}

// NewTart returns a Tart using the package's default executor.
func NewTart() *Tart {
	return &Tart{exec: DefaultExecutor}
}

// NewTartWithExecutor is for tests: inject a fake executor.
func NewTartWithExecutor(e Executor) *Tart {
	return &Tart{exec: e}
}

// Exists reports whether a VM with the given name appears in `tart list`.
func (t *Tart) Exists(ctx context.Context, name string) (bool, error) {
	out, err := t.exec.Run(ctx, "tart", "list")
	if err != nil {
		return false, fmt.Errorf("tart list: %w", err)
	}
	return parseTartListContains(string(out), name), nil
}

// IP returns the bridge VM's softnet IP, or "" if the VM is not running
// or doesn't have an IP yet. Validates that the returned value is IPv4 —
// some tart versions print error strings to stdout in error states.
func (t *Tart) IP(ctx context.Context, name string) (string, error) {
	out, err := t.exec.Run(ctx, "tart", "ip", name)
	if err != nil {
		// `tart ip` exits non-zero when the VM is stopped; return empty, no error.
		return "", nil
	}
	candidate := strings.TrimSpace(string(out))
	if candidate == "" {
		return "", nil
	}
	if net.ParseIP(candidate).To4() == nil {
		return "", fmt.Errorf("tart ip %s: unexpected output %q (not IPv4)", name, candidate)
	}
	return candidate, nil
}

// Clone clones the named base image into a new VM. No-op if the VM
// already exists.
func (t *Tart) Clone(ctx context.Context, baseImage, name string) error {
	exists, err := t.Exists(ctx, name)
	if err != nil {
		return err
	}
	if exists {
		return nil
	}
	if _, err := t.exec.Run(ctx, "tart", "clone", baseImage, name); err != nil {
		return fmt.Errorf("tart clone: %w", err)
	}
	return nil
}

// Delete deletes the named VM. No-op if it doesn't exist.
func (t *Tart) Delete(ctx context.Context, name string) error {
	exists, err := t.Exists(ctx, name)
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	if _, err := t.exec.Run(ctx, "tart", "delete", name); err != nil {
		return fmt.Errorf("tart delete: %w", err)
	}
	return nil
}

// parseTartListContains is a pure function for unit testing.
// Returns true if any data row of `tart list` output names `name` exactly
// (the second whitespace-separated column).
func parseTartListContains(out, name string) bool {
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		if fields[0] == "Source" && fields[1] == "Name" {
			continue // header row
		}
		if fields[1] == name {
			return true
		}
	}
	return false
}
```

- [ ] **Step 3: Write tests for the parser + a fake executor**

Path: `/Users/gintini/s/vm-claw/internal/vm/tart_test.go`

```go
package vm

import (
	"context"
	"errors"
	"testing"
)

func TestParseTartListContains(t *testing.T) {
	out := `Source Name        Disk Size CPU Memory Running
local  bridge-vm   50      4   8     false
oci    other-vm    50      4   8     true
`
	cases := []struct {
		query string
		want  bool
	}{
		{"bridge-vm", true},
		{"other-vm", true},
		{"missing", false},
		{"", false},
		{"Name", false}, // header row should not count
	}
	for _, tc := range cases {
		if got := parseTartListContains(out, tc.query); got != tc.want {
			t.Errorf("parseTartListContains(%q) = %v, want %v", tc.query, got, tc.want)
		}
	}
}

// fakeExecutor records calls and returns canned responses keyed by argv-joined.
type fakeExecutor struct {
	responses map[string]fakeResp
	calls     []string
}

type fakeResp struct {
	out []byte
	err error
}

func (f *fakeExecutor) Run(_ context.Context, name string, args ...string) ([]byte, error) {
	key := name
	for _, a := range args {
		key += " " + a
	}
	f.calls = append(f.calls, key)
	r, ok := f.responses[key]
	if !ok {
		return nil, errors.New("fakeExecutor: no canned response for " + key)
	}
	return r.out, r.err
}

func TestTart_Exists(t *testing.T) {
	exe := &fakeExecutor{
		responses: map[string]fakeResp{
			"tart list": {out: []byte("Source Name      \nlocal  bridge-vm 50 4 8 false\n"), err: nil},
		},
	}
	tart := NewTartWithExecutor(exe)
	got, err := tart.Exists(context.Background(), "bridge-vm")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got {
		t.Error("expected Exists=true")
	}
	got2, _ := tart.Exists(context.Background(), "missing")
	if got2 {
		t.Error("expected Exists=false for missing")
	}
}

func TestTart_IP_ValidIPv4(t *testing.T) {
	exe := &fakeExecutor{
		responses: map[string]fakeResp{
			"tart ip bridge-vm": {out: []byte("192.168.64.42\n"), err: nil},
		},
	}
	got, err := NewTartWithExecutor(exe).IP(context.Background(), "bridge-vm")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "192.168.64.42" {
		t.Errorf("expected 192.168.64.42, got %q", got)
	}
}

func TestTart_IP_NonIPv4Output(t *testing.T) {
	exe := &fakeExecutor{
		responses: map[string]fakeResp{
			"tart ip bridge-vm": {out: []byte("Error: VM not started\n"), err: nil},
		},
	}
	_, err := NewTartWithExecutor(exe).IP(context.Background(), "bridge-vm")
	if err == nil {
		t.Fatal("expected error for non-IPv4 output, got nil")
	}
}

func TestTart_IP_ErrorReturnsEmpty(t *testing.T) {
	exe := &fakeExecutor{
		responses: map[string]fakeResp{
			"tart ip bridge-vm": {out: nil, err: errors.New("exit 1")},
		},
	}
	got, err := NewTartWithExecutor(exe).IP(context.Background(), "bridge-vm")
	if err != nil {
		t.Errorf("non-zero exit should return empty string, no error; got err=%v", err)
	}
	if got != "" {
		t.Errorf("expected empty IP on tart error, got %q", got)
	}
}

func TestTart_Clone_SkipsIfExists(t *testing.T) {
	exe := &fakeExecutor{
		responses: map[string]fakeResp{
			"tart list": {out: []byte("Source Name\nlocal  bridge-vm 50 4 8 false\n"), err: nil},
		},
	}
	if err := NewTartWithExecutor(exe).Clone(context.Background(), "img", "bridge-vm"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, c := range exe.calls {
		if c == "tart clone img bridge-vm" {
			t.Error("Clone should have been a no-op when VM exists, but called tart clone")
		}
	}
}
```

- [ ] **Step 4: Run tests — should pass**

```bash
make test
```

Expected: `ok    github.com/intinig/vm-claw/internal/vm` with all parser + Tart wrapper tests passing.

- [ ] **Step 5: Commit**

```bash
git add internal/vm/exec.go internal/vm/tart.go internal/vm/tart_test.go
git commit -m "$(cat <<'EOF'
Add Tart wrapper with Executor injection

- internal/vm/exec.go: Executor interface + production execShellOut.
- internal/vm/tart.go: Tart struct with Exists/IP/Clone/Delete methods.
  - IP() validates IPv4 output; tart errors return empty string + nil err.
  - Clone/Delete are idempotent.
- Tests cover parseTartListContains, IP with valid/invalid/empty output,
  and Clone-skips-if-exists.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase C — internal/hermes package

### Task C.1: Webhook secret generate / persist / load (TDD)

**Files:**
- Create: `internal/hermes/secret.go`
- Create: `internal/hermes/secret_test.go`

- [ ] **Step 1: Write tests**

Path: `/Users/gintini/s/vm-claw/internal/hermes/secret_test.go`

```go
package hermes

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

func TestGenerateSecret_Format(t *testing.T) {
	s, err := generateSecret()
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(s) {
		t.Errorf("expected 64 hex chars, got %q (len %d)", s, len(s))
	}
}

func TestGenerateSecret_Unique(t *testing.T) {
	a, _ := generateSecret()
	b, _ := generateSecret()
	if a == b {
		t.Errorf("two consecutive generateSecret() calls returned identical output: %q", a)
	}
}

func TestPersistAndLoadSecret(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".bb-webhook-secret")

	if err := persistSecret(path, "deadbeef"); err != nil {
		t.Fatalf("persistSecret: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("expected perm 0600, got %o", info.Mode().Perm())
	}

	got, err := loadSecret(path)
	if err != nil {
		t.Fatalf("loadSecret: %v", err)
	}
	if got != "deadbeef" {
		t.Errorf("got %q, want deadbeef", got)
	}
}

func TestLoadSecret_Missing(t *testing.T) {
	_, err := loadSecret(filepath.Join(t.TempDir(), "nope"))
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestEnsureSecret_GeneratesIfAbsent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".bb-webhook-secret")

	s1, err := EnsureSecret(path)
	if err != nil {
		t.Fatalf("EnsureSecret first call: %v", err)
	}
	if len(s1) != 64 {
		t.Errorf("expected 64 hex chars, got len %d", len(s1))
	}
}

func TestEnsureSecret_ReusesExisting(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".bb-webhook-secret")

	s1, _ := EnsureSecret(path)
	s2, _ := EnsureSecret(path)

	if s1 != s2 {
		t.Errorf("EnsureSecret should reuse existing secret; got %q then %q", s1, s2)
	}
}
```

- [ ] **Step 2: Run tests — should fail to compile**

```bash
make test
```

Expected: undefined `generateSecret`, `persistSecret`, `loadSecret`, `EnsureSecret`.

- [ ] **Step 3: Implement `internal/hermes/secret.go`**

Path: `/Users/gintini/s/vm-claw/internal/hermes/secret.go`

```go
// Package hermes manages the host-side Hermes Docker stack: Colima,
// docker daemon, the ~/.hermes data directory, and the BlueBubbles
// webhook secret reused across bootstrap and finalize.
package hermes

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
)

// generateSecret returns 32 random bytes hex-encoded (64 hex chars).
// Used as the shared secret between BlueBubbles' webhook config and the
// Hermes BlueBubbles connector's expected Authorization Bearer token.
func generateSecret() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("crypto/rand: %w", err)
	}
	return hex.EncodeToString(b), nil
}

// persistSecret writes secret to path with permissions 0600. Creates
// parent directories if missing (mode 0700).
func persistSecret(path, secret string) error {
	if err := os.MkdirAll(parentDir(path), 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", parentDir(path), err)
	}
	if err := os.WriteFile(path, []byte(secret+"\n"), 0o600); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

// loadSecret reads a previously-persisted secret from path. Trims trailing
// whitespace.
func loadSecret(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", path, err)
	}
	return strings.TrimSpace(string(b)), nil
}

// EnsureSecret reads the persisted webhook secret at path, or generates +
// persists a fresh one if absent. The secret is generated exactly once
// per host and never rotated automatically — rotating means BlueBubbles'
// webhook config has to be re-edited too. Idempotent across re-runs of
// vmclaw bootstrap.
func EnsureSecret(path string) (string, error) {
	if existing, err := loadSecret(path); err == nil && existing != "" {
		return existing, nil
	}
	fresh, err := generateSecret()
	if err != nil {
		return "", err
	}
	if err := persistSecret(path, fresh); err != nil {
		return "", err
	}
	return fresh, nil
}

// parentDir returns path's directory.
func parentDir(path string) string {
	if i := strings.LastIndex(path, "/"); i >= 0 {
		return path[:i]
	}
	return "."
}
```

- [ ] **Step 4: Run tests — should pass**

```bash
make test
```

Expected: all secret tests pass.

- [ ] **Step 5: Commit**

```bash
git add internal/hermes/secret.go internal/hermes/secret_test.go
git commit -m "$(cat <<'EOF'
Add hermes.EnsureSecret for the BlueBubbles webhook token

32 bytes of crypto/rand, hex-encoded, persisted at mode 600.
EnsureSecret reads existing or generates fresh; idempotent across
re-runs. Tests cover generation format, uniqueness, persist + load,
mode 600, and the ensure-existing-or-create branch.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task C.2: Env file read / merge / write (TDD)

**Files:**
- Create: `internal/hermes/envfile.go`
- Create: `internal/hermes/envfile_test.go`

- [ ] **Step 1: Write tests**

Path: `/Users/gintini/s/vm-claw/internal/hermes/envfile_test.go`

```go
package hermes

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseEnvFile_BasicAndComments(t *testing.T) {
	in := `# header comment
FOO=bar
BAZ=qux # not a comment, value runs to EOL
EMPTY=
QUOTED="has spaces"
`
	got := parseEnvFile(in)
	want := map[string]string{
		"FOO":    "bar",
		"BAZ":    "qux # not a comment, value runs to EOL",
		"EMPTY":  "",
		"QUOTED": `"has spaces"`,
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("key %q: got %q, want %q", k, got[k], v)
		}
	}
}

func TestRenderEnvFile_PreservesUnknownLinesAndOrder(t *testing.T) {
	original := `# leading comment
FOO=bar
# section header
BAZ=qux
`
	updates := map[string]string{
		"FOO":   "newbar",
		"NEWVAR": "newval",
	}
	out := renderEnvFile(original, updates)

	// FOO should be updated in place
	if !strings.Contains(out, "FOO=newbar") {
		t.Errorf("expected FOO=newbar in output, got:\n%s", out)
	}
	if strings.Contains(out, "FOO=bar\n") {
		t.Errorf("old FOO=bar should be replaced, got:\n%s", out)
	}
	// BAZ should be unchanged
	if !strings.Contains(out, "BAZ=qux") {
		t.Errorf("unrelated key BAZ should be preserved, got:\n%s", out)
	}
	// Comments preserved
	if !strings.Contains(out, "# leading comment") || !strings.Contains(out, "# section header") {
		t.Errorf("comments should be preserved, got:\n%s", out)
	}
	// New key appended at end
	if !strings.HasSuffix(strings.TrimSpace(out), "NEWVAR=newval") {
		t.Errorf("NEWVAR should be appended at end, got:\n%s", out)
	}
}

func TestRenderEnvFile_EmptyOriginal(t *testing.T) {
	out := renderEnvFile("", map[string]string{"A": "1", "B": "2"})
	// Both keys present
	if !strings.Contains(out, "A=1") || !strings.Contains(out, "B=2") {
		t.Errorf("expected both keys in output, got:\n%s", out)
	}
}

func TestUpdateEnvFile_CreatesIfMissing_Mode600(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")

	if err := UpdateEnvFile(path, map[string]string{"A": "1"}); err != nil {
		t.Fatalf("UpdateEnvFile: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("expected mode 0600, got %o", info.Mode().Perm())
	}

	body, _ := os.ReadFile(path)
	if !strings.Contains(string(body), "A=1") {
		t.Errorf("written file missing key, got:\n%s", body)
	}
}

func TestUpdateEnvFile_PreservesAndUpdates(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	if err := os.WriteFile(path, []byte("FOO=bar\nKEEP=me\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := UpdateEnvFile(path, map[string]string{"FOO": "newbar"}); err != nil {
		t.Fatalf("UpdateEnvFile: %v", err)
	}

	body, _ := os.ReadFile(path)
	if !strings.Contains(string(body), "FOO=newbar") {
		t.Errorf("expected FOO=newbar, got:\n%s", body)
	}
	if !strings.Contains(string(body), "KEEP=me") {
		t.Errorf("expected KEEP=me preserved, got:\n%s", body)
	}
}
```

- [ ] **Step 2: Run tests — should fail to compile**

```bash
make test
```

Expected: undefined `parseEnvFile`, `renderEnvFile`, `UpdateEnvFile`.

- [ ] **Step 3: Implement `internal/hermes/envfile.go`**

Path: `/Users/gintini/s/vm-claw/internal/hermes/envfile.go`

```go
package hermes

import (
	"fmt"
	"os"
	"sort"
	"strings"
)

// BlueBubbles connector key names. **Placeholders** until the actual
// names are confirmed against current Hermes docs (see the spec's
// "Open / deferred items" section). Update these in a follow-up commit
// once the BlueBubbles connector docs are read.
const (
	BluebubblesServerURLKey     = "BLUEBUBBLES_SERVER_URL"
	BluebubblesPasswordKey      = "BLUEBUBBLES_PASSWORD"
	BluebubblesWebhookSecretKey = "BLUEBUBBLES_WEBHOOK_SECRET"
)

// parseEnvFile parses a dotenv-style file body into a map. Lines starting
// with `#` and blank lines are ignored. The first `=` separates key and
// value; everything after the `=` is the value as-is (no quote stripping,
// no comment stripping after `#` — values containing `#` are valid).
func parseEnvFile(body string) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(body, "\n") {
		trim := strings.TrimSpace(line)
		if trim == "" || strings.HasPrefix(trim, "#") {
			continue
		}
		idx := strings.Index(line, "=")
		if idx <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		val := line[idx+1:]
		out[key] = val
	}
	return out
}

// renderEnvFile rewrites original by replacing values for keys present
// in updates, preserving unknown keys, comments, and overall ordering.
// Keys in updates that don't exist in original are appended at the end
// in deterministic (sorted) order.
func renderEnvFile(original string, updates map[string]string) string {
	var b strings.Builder
	seen := map[string]bool{}

	lines := strings.Split(original, "\n")
	// Drop a single trailing empty line so we don't double-up newlines.
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}

	for _, line := range lines {
		trim := strings.TrimSpace(line)
		if trim == "" || strings.HasPrefix(trim, "#") {
			b.WriteString(line)
			b.WriteByte('\n')
			continue
		}
		idx := strings.Index(line, "=")
		if idx <= 0 {
			b.WriteString(line)
			b.WriteByte('\n')
			continue
		}
		key := strings.TrimSpace(line[:idx])
		if newVal, ok := updates[key]; ok {
			b.WriteString(key)
			b.WriteByte('=')
			b.WriteString(newVal)
			b.WriteByte('\n')
			seen[key] = true
		} else {
			b.WriteString(line)
			b.WriteByte('\n')
		}
	}

	// Append new keys in deterministic order so re-runs produce stable output.
	var newKeys []string
	for k := range updates {
		if !seen[k] {
			newKeys = append(newKeys, k)
		}
	}
	sort.Strings(newKeys)
	for _, k := range newKeys {
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(updates[k])
		b.WriteByte('\n')
	}
	return b.String()
}

// UpdateEnvFile reads the env file at path (or starts from empty if
// absent), merges in updates, writes back at mode 0600. Creates parent
// dir at mode 0700 if missing.
func UpdateEnvFile(path string, updates map[string]string) error {
	if err := os.MkdirAll(parentDir(path), 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", parentDir(path), err)
	}
	var original string
	if b, err := os.ReadFile(path); err == nil {
		original = string(b)
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("read %s: %w", path, err)
	}

	rendered := renderEnvFile(original, updates)

	if err := os.WriteFile(path, []byte(rendered), 0o600); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}
```

- [ ] **Step 4: Run tests — should pass**

```bash
make test
```

Expected: all envfile tests pass.

- [ ] **Step 5: Commit**

```bash
git add internal/hermes/envfile.go internal/hermes/envfile_test.go
git commit -m "$(cat <<'EOF'
Add hermes.UpdateEnvFile + BlueBubbles connector key constants

- parseEnvFile: dotenv-style parser, comments and blank lines ignored.
- renderEnvFile: in-place value updates, comments/order preserved,
  new keys appended in sorted order for deterministic output.
- UpdateEnvFile: read-merge-write at mode 0600, creates parent dir
  at 0700 if missing.
- BluebubblesServerURLKey / PasswordKey / WebhookSecretKey constants
  are PLACEHOLDERS — actual names need verification against current
  Hermes docs (deferred per the spec).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task C.3: Colima wrappers (integration-only, no TDD ceremony)

**Files:**
- Create: `internal/hermes/colima.go`

The Colima wrapper shells out to `colima` and `brew`. Pure integration territory — testable only with the actual binaries on a real Colima install. We don't write unit tests; we write the smallest reasonable wrapper and rely on `make integration` (later) and end-to-end smoke testing.

- [ ] **Step 1: Write `internal/hermes/colima.go`**

Path: `/Users/gintini/s/vm-claw/internal/hermes/colima.go`

```go
package hermes

import (
	"context"
	"fmt"
	"strings"

	"github.com/intinig/vm-claw/internal/vm"
)

// ColimaConfig configures the Colima VM that hosts the docker daemon.
type ColimaConfig struct {
	Profile  string // colima profile name
	CPU      int
	MemoryGB int
	DiskGB   int
	VMType   string // "vz" on Apple Silicon, "qemu" otherwise
}

// DefaultColimaConfig is the project default. Matches the constants from
// the now-deleted hermes-setup.sh.
func DefaultColimaConfig() ColimaConfig {
	return ColimaConfig{
		Profile:  "default",
		CPU:      4,
		MemoryGB: 8,
		DiskGB:   80,
		VMType:   "vz",
	}
}

// Colima wraps the colima CLI.
type Colima struct {
	exec vm.Executor
}

// NewColima returns a Colima wrapper using the production executor.
func NewColima() *Colima { return &Colima{exec: vm.DefaultExecutor} }

// IsRunning returns true if `colima status -p <profile>` exits 0.
func (c *Colima) IsRunning(ctx context.Context, profile string) (bool, error) {
	if _, err := c.exec.Run(ctx, "colima", "status", "-p", profile); err != nil {
		// colima status exits non-zero when the profile is stopped.
		return false, nil
	}
	return true, nil
}

// Start starts a Colima profile if not already running. Idempotent.
func (c *Colima) Start(ctx context.Context, cfg ColimaConfig) error {
	running, err := c.IsRunning(ctx, cfg.Profile)
	if err != nil {
		return err
	}
	if running {
		return nil
	}
	args := []string{
		"start",
		"-p", cfg.Profile,
		"--vm-type", cfg.VMType,
		"--cpu", fmt.Sprintf("%d", cfg.CPU),
		"--memory", fmt.Sprintf("%d", cfg.MemoryGB),
		"--disk", fmt.Sprintf("%d", cfg.DiskGB),
	}
	if _, err := c.exec.Run(ctx, "colima", args...); err != nil {
		return fmt.Errorf("colima start: %w", err)
	}
	return nil
}

// EnsureBrewInstalled returns nil if `brew` is on PATH, error otherwise.
// We don't auto-install Homebrew — the user does that themselves.
func EnsureBrewInstalled(ctx context.Context, exec vm.Executor) error {
	if _, err := exec.Run(ctx, "command", "-v", "brew"); err != nil {
		return fmt.Errorf("brew not found on PATH; install from https://brew.sh first")
	}
	return nil
}

// EnsurePackagesInstalled brew-installs packages that aren't already
// present. Skips packages that brew reports as installed.
// Returns nil if all packages end up installed.
func EnsurePackagesInstalled(ctx context.Context, exec vm.Executor, packages ...string) error {
	for _, pkg := range packages {
		out, err := exec.Run(ctx, "brew", "list", "--versions", pkg)
		if err == nil && strings.TrimSpace(string(out)) != "" {
			continue // already installed
		}
		if _, err := exec.Run(ctx, "brew", "install", pkg); err != nil {
			return fmt.Errorf("brew install %s: %w", pkg, err)
		}
	}
	return nil
}
```

- [ ] **Step 2: Verify it compiles**

```bash
make build
```

Expected: clean build. No tests yet for this file — they'd be integration territory and the package's other test files still pass.

- [ ] **Step 3: Run existing tests to confirm no regression**

```bash
make test
```

Expected: all existing tests still pass (`internal/hermes` and `internal/vm`).

- [ ] **Step 4: Commit**

```bash
git add internal/hermes/colima.go
git commit -m "$(cat <<'EOF'
Add hermes.Colima wrapper + brew helpers

- ColimaConfig with project defaults (4 CPU / 8 GB / 80 GB / vz).
- IsRunning / Start, both idempotent (Start no-ops if already running).
- EnsureBrewInstalled (probes for brew on PATH; user installs Homebrew
  themselves).
- EnsurePackagesInstalled (brew install only if not already present).

Integration territory — no unit tests added. Verified via build only.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task C.4: Docker wrappers (integration-only)

**Files:**
- Create: `internal/hermes/docker.go`

- [ ] **Step 1: Write `internal/hermes/docker.go`**

Path: `/Users/gintini/s/vm-claw/internal/hermes/docker.go`

```go
package hermes

import (
	"context"
	"fmt"
	"strings"

	"github.com/intinig/vm-claw/internal/vm"
)

// HermesConfig is the per-profile configuration for the Hermes container
// stack. Mirrors the env vars that the deleted hermes-setup.sh consumed.
type HermesConfig struct {
	ProfileName    string // hermes profile (default: "default")
	HermesHome     string // host data dir bind-mounted to /opt/data
	GatewayName    string // gateway container name
	DashboardName  string // dashboard container name
	GatewayPort    int    // host port for gateway
	DashboardPort  int    // host port for dashboard
	Network        string // docker network shared by gateway+dashboard
	Image          string // hermes-agent image ref
	SandboxImage   string // sandbox image (nikolaik/python-nodejs)
}

// DefaultHermesConfig is the standard config for profile "default".
func DefaultHermesConfig(homeDir string) HermesConfig {
	return HermesConfig{
		ProfileName:   "default",
		HermesHome:    homeDir + "/.hermes",
		GatewayName:   "hermes",
		DashboardName: "hermes-dashboard",
		GatewayPort:   8642,
		DashboardPort: 9119,
		Network:       "hermes-net-default",
		Image:         "nousresearch/hermes-agent:latest",
		SandboxImage:  "nikolaik/python-nodejs:python3.11-nodejs20",
	}
}

// Docker wraps the docker CLI.
type Docker struct {
	exec vm.Executor
}

func NewDocker() *Docker { return &Docker{exec: vm.DefaultExecutor} }

// PullImage pulls an image. Idempotent (docker re-uses cached layers).
func (d *Docker) PullImage(ctx context.Context, image string) error {
	if _, err := d.exec.Run(ctx, "docker", "pull", image); err != nil {
		return fmt.Errorf("docker pull %s: %w", image, err)
	}
	return nil
}

// EnsureNetwork creates the named docker network if it doesn't exist.
func (d *Docker) EnsureNetwork(ctx context.Context, name string) error {
	if _, err := d.exec.Run(ctx, "docker", "network", "inspect", name); err == nil {
		return nil
	}
	if _, err := d.exec.Run(ctx, "docker", "network", "create", name); err != nil {
		return fmt.Errorf("docker network create %s: %w", name, err)
	}
	return nil
}

// ContainerExists returns true if a container with the given name exists
// (running or stopped).
func (d *Docker) ContainerExists(ctx context.Context, name string) (bool, error) {
	out, err := d.exec.Run(ctx, "docker", "ps", "-a", "--filter", "name=^"+name+"$", "--format", "{{.Names}}")
	if err != nil {
		return false, fmt.Errorf("docker ps: %w", err)
	}
	return strings.TrimSpace(string(out)) == name, nil
}

// ContainerRunning returns true if the named container exists and is running.
func (d *Docker) ContainerRunning(ctx context.Context, name string) (bool, error) {
	out, err := d.exec.Run(ctx, "docker", "ps", "--filter", "name=^"+name+"$", "--format", "{{.Names}}")
	if err != nil {
		return false, fmt.Errorf("docker ps: %w", err)
	}
	return strings.TrimSpace(string(out)) == name, nil
}

// RemoveContainer stops and removes a container by name. No-op if absent.
func (d *Docker) RemoveContainer(ctx context.Context, name string) error {
	exists, err := d.ContainerExists(ctx, name)
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	_, _ = d.exec.Run(ctx, "docker", "stop", name) // best effort
	if _, err := d.exec.Run(ctx, "docker", "rm", "-f", name); err != nil {
		return fmt.Errorf("docker rm: %w", err)
	}
	return nil
}

// RunHermesGateway starts the gateway container with --add-host
// bridge-vm:<bridgeIP>. Removes any existing container with the same
// name first.
func (d *Docker) RunHermesGateway(ctx context.Context, cfg HermesConfig, bridgeIP string) error {
	if err := d.RemoveContainer(ctx, cfg.GatewayName); err != nil {
		return err
	}
	args := []string{
		"run", "-d",
		"--name", cfg.GatewayName,
		"--restart", "unless-stopped",
		"--network", cfg.Network,
		"--add-host", "bridge-vm:" + bridgeIP,
		"-v", cfg.HermesHome + ":/opt/data",
		"-p", fmt.Sprintf("%d:8642", cfg.GatewayPort),
		"--memory", "4g",
		"--cpus", "2",
		"--shm-size", "1g",
		cfg.Image,
		"gateway", "run",
	}
	if _, err := d.exec.Run(ctx, "docker", args...); err != nil {
		return fmt.Errorf("docker run hermes gateway: %w", err)
	}
	return nil
}
```

- [ ] **Step 2: Verify build + tests**

```bash
make build && make test
```

Expected: clean build, existing tests pass.

- [ ] **Step 3: Commit**

```bash
git add internal/hermes/docker.go
git commit -m "$(cat <<'EOF'
Add hermes.Docker wrapper

- HermesConfig struct + DefaultHermesConfig factory matching the
  deleted hermes-setup.sh defaults.
- PullImage, EnsureNetwork, ContainerExists, ContainerRunning,
  RemoveContainer (idempotent), RunHermesGateway (with --add-host
  bridge-vm:<ip> baked in).

Integration territory; no unit tests.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase D — internal/launchagent package

### Task D.1: Plist render + install/uninstall (TDD on render)

**Files:**
- Create: `internal/launchagent/template.plist`
- Create: `internal/launchagent/plist.go`
- Create: `internal/launchagent/plist_test.go`

- [ ] **Step 1: Write the embedded plist template**

Path: `/Users/gintini/s/vm-claw/internal/launchagent/template.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{{.Label}}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{{.TartPath}}</string>
    <string>run</string>
    <string>--net-softnet</string>
    <string>{{.VMName}}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>/tmp/{{.Label}}.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/{{.Label}}.err.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Write tests for the renderer**

Path: `/Users/gintini/s/vm-claw/internal/launchagent/plist_test.go`

```go
package launchagent

import (
	"strings"
	"testing"
)

func TestRender_BasicSubstitution(t *testing.T) {
	out, err := render(Options{
		Label:    "com.vm-claw.bridge-vm",
		TartPath: "/opt/homebrew/bin/tart",
		VMName:   "bridge-vm",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"<string>com.vm-claw.bridge-vm</string>",
		"<string>/opt/homebrew/bin/tart</string>",
		"<string>--net-softnet</string>",
		"<string>bridge-vm</string>",
		"/tmp/com.vm-claw.bridge-vm.out.log",
		"/tmp/com.vm-claw.bridge-vm.err.log",
	}
	for _, w := range want {
		if !strings.Contains(string(out), w) {
			t.Errorf("expected output to contain %q, got:\n%s", w, out)
		}
	}
}

func TestRender_RejectsEmptyFields(t *testing.T) {
	cases := []Options{
		{TartPath: "/opt/homebrew/bin/tart", VMName: "bridge-vm"},      // empty Label
		{Label: "com.vm-claw.x", VMName: "bridge-vm"},                   // empty TartPath
		{Label: "com.vm-claw.x", TartPath: "/opt/homebrew/bin/tart"},    // empty VMName
	}
	for i, c := range cases {
		if _, err := render(c); err == nil {
			t.Errorf("case %d: expected error for empty field, got nil", i)
		}
	}
}
```

- [ ] **Step 3: Run tests — should fail to compile**

```bash
make test
```

Expected: undefined `render`, `Options`.

- [ ] **Step 4: Implement `internal/launchagent/plist.go`**

Path: `/Users/gintini/s/vm-claw/internal/launchagent/plist.go`

```go
// Package launchagent installs and uninstalls the bridge VM's
// auto-start LaunchAgent under ~/Library/LaunchAgents.
package launchagent

import (
	"bytes"
	"context"
	_ "embed"
	"fmt"
	"os"
	"path/filepath"
	"text/template"

	"github.com/intinig/vm-claw/internal/vm"
)

// Default Label used by the installer when Options.Label is empty
// at the high-level Install/Uninstall API. Matches the path embedded
// in CLAUDE.md's "Recovery paths" section.
const DefaultLabel = "com.vm-claw.bridge-vm"

//go:embed template.plist
var templateBody string

// Options templated into the plist.
type Options struct {
	Label    string // launchctl Label (also used as the plist filename stem)
	TartPath string // absolute path to tart binary
	VMName   string // VM name passed to `tart run --net-softnet`
}

// render templates the plist body. Returns an error if any required
// field is empty.
func render(opts Options) ([]byte, error) {
	if opts.Label == "" || opts.TartPath == "" || opts.VMName == "" {
		return nil, fmt.Errorf("plist render: Label, TartPath, and VMName all required (got %#v)", opts)
	}
	t, err := template.New("plist").Parse(templateBody)
	if err != nil {
		return nil, fmt.Errorf("plist parse: %w", err)
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, opts); err != nil {
		return nil, fmt.Errorf("plist execute: %w", err)
	}
	return buf.Bytes(), nil
}

// PlistPath returns the on-disk path for the LaunchAgent plist with
// the given label, under ~/Library/LaunchAgents/<label>.plist.
func PlistPath(homeDir, label string) string {
	return filepath.Join(homeDir, "Library", "LaunchAgents", label+".plist")
}

// IsLoaded returns true if the LaunchAgent with the given label appears
// in `launchctl list`.
func IsLoaded(ctx context.Context, exec vm.Executor, label string) (bool, error) {
	out, err := exec.Run(ctx, "launchctl", "list")
	if err != nil {
		return false, fmt.Errorf("launchctl list: %w", err)
	}
	return bytes.Contains(out, []byte(label)), nil
}

// Install renders the plist, writes it to ~/Library/LaunchAgents,
// and launchctl-loads it. Idempotent: unloads any existing plist
// at the same path before reloading so re-runs reflect new options.
func Install(ctx context.Context, exec vm.Executor, homeDir string, opts Options) error {
	if opts.Label == "" {
		opts.Label = DefaultLabel
	}
	body, err := render(opts)
	if err != nil {
		return err
	}
	path := PlistPath(homeDir, opts.Label)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("mkdir LaunchAgents: %w", err)
	}
	// Best-effort unload before overwriting (no-op if not loaded).
	_, _ = exec.Run(ctx, "launchctl", "unload", path)
	if err := os.WriteFile(path, body, 0o644); err != nil {
		return fmt.Errorf("write plist: %w", err)
	}
	if _, err := exec.Run(ctx, "launchctl", "load", path); err != nil {
		return fmt.Errorf("launchctl load: %w", err)
	}
	return nil
}

// Uninstall unloads and removes the LaunchAgent plist. Idempotent.
func Uninstall(ctx context.Context, exec vm.Executor, homeDir, label string) error {
	if label == "" {
		label = DefaultLabel
	}
	path := PlistPath(homeDir, label)
	_, _ = exec.Run(ctx, "launchctl", "unload", path) // best effort
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove plist: %w", err)
	}
	return nil
}
```

- [ ] **Step 5: Run tests — should pass**

```bash
make test
```

Expected: render tests pass.

- [ ] **Step 6: Commit**

```bash
git add internal/launchagent/template.plist internal/launchagent/plist.go internal/launchagent/plist_test.go
git commit -m "$(cat <<'EOF'
Add launchagent package: plist render + install/uninstall

- template.plist embedded via //go:embed.
- render() validates required fields, returns templated bytes.
- Install/Uninstall idempotent. Install best-effort-unloads any
  existing plist at the same path before rewriting + launchctl load.
- PlistPath helper exposes the on-disk location.

Tests cover render substitution and required-field validation.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase E — internal/doctor package

### Task E.1: Check struct + healthcheck rows

**Files:**
- Create: `internal/doctor/checks.go`

Each healthcheck row is a `Check` (a function returning Pass/Fail/Skip + a message). Most rows shell out to real systems — pure integration territory, no unit tests.

- [ ] **Step 1: Implement `internal/doctor/checks.go`**

Path: `/Users/gintini/s/vm-claw/internal/doctor/checks.go`

```go
// Package doctor runs end-to-end healthchecks against the running
// vm-claw stack. Each Check is independently runnable and reports
// OK / FAIL / SKIP with a one-line message.
package doctor

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/intinig/vm-claw/internal/vm"
)

// Status of one healthcheck row.
type Status int

const (
	StatusOK   Status = iota // healthy
	StatusFail               // unhealthy; doctor exits non-zero if any
	StatusSkip               // not applicable in this configuration
)

func (s Status) String() string {
	switch s {
	case StatusOK:
		return "OK"
	case StatusFail:
		return "FAIL"
	case StatusSkip:
		return "SKIP"
	}
	return "?"
}

// Result is the outcome of one Check.
type Result struct {
	Name    string
	Status  Status
	Message string
}

// Check runs one row and returns a Result. ctx allows timeouts.
type Check func(ctx context.Context) Result

// Config controls which checks run and what they expect.
type Config struct {
	Executor      vm.Executor // tart, docker, etc.
	VMName        string      // bridge VM name
	BBPort        int         // BlueBubbles port (default 1234)
	BBPassword    string      // BB admin password; if "", checks that need it Skip
	HermesGateway string      // gateway container name (default "hermes")
}

// DefaultChecks returns the standard set of healthcheck rows in run order.
func DefaultChecks(cfg Config) []struct {
	Name string
	Run  Check
} {
	tart := vm.NewTartWithExecutor(cfg.Executor)
	if cfg.BBPort == 0 {
		cfg.BBPort = 1234
	}
	if cfg.HermesGateway == "" {
		cfg.HermesGateway = "hermes"
	}

	return []struct {
		Name string
		Run  Check
	}{
		{"tart binary present", func(ctx context.Context) Result {
			if _, err := cfg.Executor.Run(ctx, "command", "-v", "tart"); err != nil {
				return Result{Status: StatusFail, Message: "tart not on PATH (brew install cirruslabs/cli/tart)"}
			}
			return Result{Status: StatusOK, Message: "found"}
		}},

		{"bridge VM exists", func(ctx context.Context) Result {
			ok, err := tart.Exists(ctx, cfg.VMName)
			if err != nil {
				return Result{Status: StatusFail, Message: err.Error()}
			}
			if !ok {
				return Result{Status: StatusFail, Message: "VM '" + cfg.VMName + "' not in tart list (run `vmclaw vm create`)"}
			}
			return Result{Status: StatusOK, Message: cfg.VMName}
		}},

		{"bridge VM has IP", func(ctx context.Context) Result {
			ip, err := tart.IP(ctx, cfg.VMName)
			if err != nil {
				return Result{Status: StatusFail, Message: err.Error()}
			}
			if ip == "" {
				return Result{Status: StatusFail, Message: "VM not running (run `vmclaw vm run` or load LaunchAgent)"}
			}
			return Result{Status: StatusOK, Message: ip}
		}},

		{"BlueBubbles reachable from host", func(ctx context.Context) Result {
			ip, _ := tart.IP(ctx, cfg.VMName)
			if ip == "" {
				return Result{Status: StatusSkip, Message: "no VM IP yet"}
			}
			url := fmt.Sprintf("http://%s:%d/api/v1/server/info", ip, cfg.BBPort)
			if cfg.BBPassword != "" {
				url += "?password=" + cfg.BBPassword
			}
			if err := probeHTTP(ctx, url, 3*time.Second); err != nil {
				return Result{Status: StatusFail, Message: err.Error()}
			}
			return Result{Status: StatusOK, Message: "200 from " + url}
		}},

		{"docker daemon reachable", func(ctx context.Context) Result {
			if _, err := cfg.Executor.Run(ctx, "docker", "version"); err != nil {
				return Result{Status: StatusFail, Message: "docker not reachable (start colima?)"}
			}
			return Result{Status: StatusOK, Message: "responding"}
		}},

		{"hermes gateway container running", func(ctx context.Context) Result {
			out, err := cfg.Executor.Run(ctx, "docker", "ps", "--filter", "name=^"+cfg.HermesGateway+"$", "--format", "{{.Names}}")
			if err != nil {
				return Result{Status: StatusFail, Message: err.Error()}
			}
			if strings.TrimSpace(string(out)) != cfg.HermesGateway {
				return Result{Status: StatusFail, Message: "container '" + cfg.HermesGateway + "' not running"}
			}
			return Result{Status: StatusOK, Message: "running"}
		}},

		{"container resolves bridge-vm and reaches BlueBubbles", func(ctx context.Context) Result {
			ip, _ := tart.IP(ctx, cfg.VMName)
			if ip == "" {
				return Result{Status: StatusSkip, Message: "no VM IP"}
			}
			url := "http://bridge-vm:" + fmt.Sprintf("%d", cfg.BBPort) + "/api/v1/server/info"
			if cfg.BBPassword != "" {
				url += "?password=" + cfg.BBPassword
			}
			args := []string{
				"exec", cfg.HermesGateway,
				"wget", "-q", "--timeout=5", "-O-", url,
			}
			if _, err := cfg.Executor.Run(ctx, "docker", args...); err != nil {
				return Result{Status: StatusFail, Message: "container can't reach " + url + " (--add-host wired? vmnet↔softnet routing OK?)"}
			}
			return Result{Status: StatusOK, Message: "via http://bridge-vm:" + fmt.Sprintf("%d", cfg.BBPort)}
		}},
	}
}

// probeHTTP issues a GET with timeout and returns non-nil on non-2xx
// or any network error.
func probeHTTP(ctx context.Context, url string, timeout time.Duration) error {
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(cctx, "GET", url, nil)
	if err != nil {
		return err
	}
	dialer := &net.Dialer{Timeout: timeout}
	tr := &http.Transport{
		DialContext:           dialer.DialContext,
		TLSHandshakeTimeout:   timeout,
		ResponseHeaderTimeout: timeout,
	}
	client := &http.Client{Transport: tr, Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

// Run executes all checks in order, prints OK/FAIL/SKIP per row to w,
// and returns the count of failed rows (0 == green).
func Run(ctx context.Context, w io.Writer, cfg Config) int {
	checks := DefaultChecks(cfg)
	failed := 0
	for _, c := range checks {
		res := c.Run(ctx)
		fmt.Fprintf(w, "  [%s]  %-50s %s\n", res.Status, c.Name, res.Message)
		if res.Status == StatusFail {
			failed++
		}
	}
	return failed
}
```

- [ ] **Step 2: Verify build + existing tests**

```bash
make build && make test
```

Expected: clean build, existing tests still pass.

- [ ] **Step 3: Commit**

```bash
git add internal/doctor/checks.go
git commit -m "$(cat <<'EOF'
Add doctor package: 7 healthcheck rows

- Status / Result / Check types.
- DefaultChecks builds the standard 7-row check set in run order:
  tart binary, VM exists, VM IP, BlueBubbles reachable from host,
  docker daemon, hermes gateway running, container reaches bridge-vm.
- Run(ctx, w, cfg) prints OK/FAIL/SKIP per row, returns fail count.
- probeHTTP uses net/http with per-request timeout.

Integration territory; tests deferred to integration phase.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase F — Cobra command handlers

### Task F.1: `vmclaw vm` namespace

**Files:**
- Create: `internal/cli/vm.go`

- [ ] **Step 1: Implement `internal/cli/vm.go`**

Path: `/Users/gintini/s/vm-claw/internal/cli/vm.go`

```go
package cli

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/intinig/vm-claw/internal/launchagent"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
)

const (
	defaultVMName    = "bridge-vm"
	defaultBaseImage = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
)

var (
	vmName        string
	vmBaseImage   string
	vmDestroyYes  bool
	vmAgentLabel  string
)

func init() {
	vmCmd := &cobra.Command{
		Use:   "vm",
		Short: "Manage the bridge Tart VM",
	}
	vmCmd.PersistentFlags().StringVar(&vmName, "name", envOr("BRIDGE_VM_NAME", defaultVMName), "VM name")

	vmCreateCmd := &cobra.Command{
		Use:   "create",
		Short: "Clone the Tahoe base image into the bridge VM",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			if err := vm.VmnetCollisionCheck(); err != nil {
				return err
			}
			tart := vm.NewTart()
			exists, err := tart.Exists(ctx, vmName)
			if err != nil {
				return err
			}
			if exists {
				fmt.Fprintf(cmd.OutOrStdout(), "[SKIP]  VM %q already exists\n", vmName)
				return nil
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[DOING] tart clone %s %s\n", vmBaseImage, vmName)
			if err := tart.Clone(ctx, vmBaseImage, vmName); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[OK]    VM %q ready\n", vmName)
			return nil
		},
	}
	vmCreateCmd.Flags().StringVar(&vmBaseImage, "base-image", defaultBaseImage, "Tart base image")

	vmRunCmd := &cobra.Command{
		Use:   "run",
		Short: "Boot the bridge VM with --net-softnet (foreground)",
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := vm.VmnetCollisionCheck(); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[DOING] tart run --net-softnet %s\n", vmName)
			tartCmd := exec.CommandContext(cmd.Context(), "tart", "run", "--net-softnet", vmName)
			tartCmd.Stdin = os.Stdin
			tartCmd.Stdout = os.Stdout
			tartCmd.Stderr = os.Stderr
			return tartCmd.Run()
		},
	}

	vmDestroyCmd := &cobra.Command{
		Use:   "destroy",
		Short: "Delete the bridge VM",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			tart := vm.NewTart()
			exists, err := tart.Exists(ctx, vmName)
			if err != nil {
				return err
			}
			if !exists {
				fmt.Fprintf(cmd.OutOrStdout(), "[SKIP]  VM %q does not exist\n", vmName)
				return nil
			}
			if !vmDestroyYes {
				fmt.Fprintf(cmd.OutOrStdout(), "This will permanently delete the VM %q.\n", vmName)
				fmt.Fprintf(cmd.OutOrStdout(), "Are you sure? [y/N] ")
				reader := bufio.NewReader(os.Stdin)
				answer, _ := reader.ReadString('\n')
				answer = strings.ToLower(strings.TrimSpace(answer))
				if answer != "y" && answer != "yes" {
					fmt.Fprintln(cmd.OutOrStdout(), "Aborted.")
					return nil
				}
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[DOING] tart delete %s\n", vmName)
			if err := tart.Delete(ctx, vmName); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[OK]    VM %q destroyed\n", vmName)
			return nil
		},
	}
	vmDestroyCmd.Flags().BoolVar(&vmDestroyYes, "yes", false, "Skip confirmation prompt")

	vmInstallAgentCmd := &cobra.Command{
		Use:   "install-agent",
		Short: "Install the LaunchAgent that auto-starts the bridge VM at user login",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			tartPath, err := exec.LookPath("tart")
			if err != nil {
				return fmt.Errorf("tart not on PATH; install with `brew install cirruslabs/cli/tart`")
			}
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			label := vmAgentLabel
			if label == "" {
				label = launchagent.DefaultLabel
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[DOING] writing %s\n", launchagent.PlistPath(home, label))
			if err := launchagent.Install(ctx, vm.DefaultExecutor, home, launchagent.Options{
				Label:    label,
				TartPath: tartPath,
				VMName:   vmName,
			}); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[OK]    LaunchAgent %q loaded\n", label)
			return nil
		},
	}
	vmInstallAgentCmd.Flags().StringVar(&vmAgentLabel, "label", "", "LaunchAgent Label (default: "+launchagent.DefaultLabel+")")

	vmUninstallAgentCmd := &cobra.Command{
		Use:   "uninstall-agent",
		Short: "Unload and remove the bridge VM's LaunchAgent",
		RunE: func(cmd *cobra.Command, args []string) error {
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			label := vmAgentLabel
			if label == "" {
				label = launchagent.DefaultLabel
			}
			if err := launchagent.Uninstall(cmd.Context(), vm.DefaultExecutor, home, label); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[OK]    LaunchAgent %q removed\n", label)
			return nil
		},
	}

	vmCmd.AddCommand(vmCreateCmd, vmRunCmd, vmDestroyCmd, vmInstallAgentCmd, vmUninstallAgentCmd)
	rootCmd.AddCommand(vmCmd)
}

// envOr returns os.Getenv(key) if non-empty, else fallback.
func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

```

- [ ] **Step 2: Build + smoke test**

```bash
make build
./bin/vmclaw vm --help
./bin/vmclaw vm create --help
./bin/vmclaw vm destroy --help
```

Expected: each prints Cobra-default help with the right flags. No actual VM operations performed.

- [ ] **Step 3: Verify tests still pass**

```bash
make test
```

Expected: existing tests pass. No new tests for CLI handlers — Cobra wiring is best verified via smoke + integration tests later.

- [ ] **Step 4: Commit**

```bash
git add internal/cli/vm.go
git commit -m "$(cat <<'EOF'
Add `vmclaw vm` subcommand handlers

- vm create / run / destroy / install-agent / uninstall-agent
- Persistent --name flag with BRIDGE_VM_NAME env fallback
- destroy --yes skips the confirmation prompt
- install-agent finds tart via PATH lookup and templates the plist

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task F.2: `vmclaw hermes` namespace

**Files:**
- Create: `internal/cli/hermes.go`

- [ ] **Step 1: Implement `internal/cli/hermes.go`**

Path: `/Users/gintini/s/vm-claw/internal/cli/hermes.go`

```go
package cli

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/intinig/vm-claw/internal/hermes"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

const (
	defaultBBPort = 1234
)

func init() {
	hermesCmd := &cobra.Command{
		Use:   "hermes",
		Short: "Manage the host-side Hermes Docker stack",
	}

	hermesBootstrapCmd := &cobra.Command{
		Use:   "bootstrap",
		Short: "Install Colima/docker, start Colima, pull Hermes images, create ~/.hermes",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			out := cmd.OutOrStdout()

			fmt.Fprintln(out, "==> Ensuring brew + container runtime")
			if err := hermes.EnsureBrewInstalled(ctx, vm.DefaultExecutor); err != nil {
				return err
			}
			if err := hermes.EnsurePackagesInstalled(ctx, vm.DefaultExecutor, "colima", "docker", "docker-compose"); err != nil {
				return err
			}

			fmt.Fprintln(out, "==> Starting Colima")
			colima := hermes.NewColima()
			cfg := hermes.DefaultColimaConfig()
			if err := colima.Start(ctx, cfg); err != nil {
				return err
			}

			fmt.Fprintln(out, "==> Pulling Hermes images")
			docker := hermes.NewDocker()
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			hcfg := hermes.DefaultHermesConfig(home)
			if err := docker.PullImage(ctx, hcfg.Image); err != nil {
				return err
			}
			if err := docker.PullImage(ctx, hcfg.SandboxImage); err != nil {
				return err
			}

			fmt.Fprintln(out, "==> Preparing ~/.hermes")
			if err := os.MkdirAll(hcfg.HermesHome, 0o700); err != nil {
				return fmt.Errorf("mkdir %s: %w", hcfg.HermesHome, err)
			}

			fmt.Fprintln(out, "==> Ensuring docker network")
			if err := docker.EnsureNetwork(ctx, hcfg.Network); err != nil {
				return err
			}

			fmt.Fprintln(out, "[OK]    hermes bootstrap complete")
			return nil
		},
	}

	hermesWireCmd := &cobra.Command{
		Use:   "wire",
		Short: "Write BlueBubbles config to ~/.hermes/.env and restart Hermes gateway",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			out := cmd.OutOrStdout()

			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			secretPath := filepath.Join(home, ".hermes", ".bb-webhook-secret")
			envPath := filepath.Join(home, ".hermes", ".env")

			secret, err := loadSecretOrErr(secretPath)
			if err != nil {
				return err
			}

			tart := vm.NewTart()
			ip, err := tart.IP(ctx, vmName)
			if err != nil {
				return err
			}
			if ip == "" {
				return fmt.Errorf("VM %q not running; run `vmclaw vm run` or load the LaunchAgent first", vmName)
			}

			password, err := promptPassword(out, "BlueBubbles admin password: ")
			if err != nil {
				return err
			}

			// Validate the password against BlueBubbles' API.
			if err := probeBlueBubblesAuth(ctx, ip, defaultBBPort, password); err != nil {
				return fmt.Errorf("password rejected by BlueBubbles: %w", err)
			}

			// Persist BlueBubbles connector keys.
			updates := map[string]string{
				hermes.BluebubblesServerURLKey:     "http://bridge-vm:" + fmt.Sprintf("%d", defaultBBPort),
				hermes.BluebubblesPasswordKey:      password,
				hermes.BluebubblesWebhookSecretKey: secret,
			}
			if err := hermes.UpdateEnvFile(envPath, updates); err != nil {
				return err
			}
			fmt.Fprintf(out, "[OK]    wrote %d keys to %s\n", len(updates), envPath)

			// Restart gateway with --add-host bridge-vm:<ip>.
			docker := hermes.NewDocker()
			hcfg := hermes.DefaultHermesConfig(home)
			fmt.Fprintf(out, "[DOING] restarting %q with --add-host bridge-vm:%s\n", hcfg.GatewayName, ip)
			if err := docker.RunHermesGateway(ctx, hcfg, ip); err != nil {
				return err
			}
			fmt.Fprintln(out, "[OK]    Hermes gateway running")
			return nil
		},
	}

	hermesCmd.AddCommand(hermesBootstrapCmd, hermesWireCmd)
	rootCmd.AddCommand(hermesCmd)
}

// loadSecretOrErr returns a friendly error if the secret file is missing.
func loadSecretOrErr(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fmt.Errorf("missing %s — run `vmclaw bootstrap` first to generate it", path)
		}
		return "", err
	}
	return strings.TrimSpace(string(b)), nil
}

// promptPassword prints a prompt to w and reads a masked password from stdin.
// Falls back to non-masked read if stdin isn't a terminal (e.g., piped tests).
func promptPassword(w interface {
	Write([]byte) (int, error)
}, prompt string) (string, error) {
	fmt.Fprint(w, prompt)
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		var s string
		if _, err := fmt.Fscanln(os.Stdin, &s); err != nil {
			return "", err
		}
		return s, nil
	}
	b, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(w)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// probeBlueBubblesAuth verifies the password by hitting
// /api/v1/server/info?password=<pw>. Confirm the actual liveness/auth
// path against current BlueBubbles docs at implementation time.
func probeBlueBubblesAuth(ctx context.Context, ip string, port int, password string) error {
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	url := fmt.Sprintf("http://%s:%d/api/v1/server/info?password=%s", ip, port, password)
	req, err := http.NewRequestWithContext(cctx, "GET", url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		return fmt.Errorf("HTTP %d (wrong password?)", resp.StatusCode)
	}
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("HTTP %d (BlueBubbles unhealthy?)", resp.StatusCode)
	}
	return nil
}
```

- [ ] **Step 2: Add `golang.org/x/term` dependency and rebuild**

```bash
go get golang.org/x/term
go mod tidy
make build
./bin/vmclaw hermes --help
./bin/vmclaw hermes bootstrap --help
./bin/vmclaw hermes wire --help
```

Expected: clean build, all three help outputs.

- [ ] **Step 3: Run tests**

```bash
make test
```

Expected: existing tests pass.

- [ ] **Step 4: Commit**

```bash
git add internal/cli/hermes.go go.mod go.sum
git commit -m "$(cat <<'EOF'
Add `vmclaw hermes` subcommand handlers

- hermes bootstrap: brew install + colima start + image pulls + ~/.hermes
  + docker network create. Each step idempotent.
- hermes wire: prompts (masked) for BlueBubbles password, validates
  against BB API, writes BLUEBUBBLES_* keys to ~/.hermes/.env, restarts
  the Hermes gateway container with --add-host bridge-vm:<ip>.
- promptPassword falls back to non-masked input when stdin isn't a TTY
  (so integration tests can pipe).

golang.org/x/term added for masked password input.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task F.3: `vmclaw doctor`

**Files:**
- Create: `internal/cli/doctor.go`

- [ ] **Step 1: Implement `internal/cli/doctor.go`**

Path: `/Users/gintini/s/vm-claw/internal/cli/doctor.go`

```go
package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/intinig/vm-claw/internal/doctor"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
)

func init() {
	doctorCmd := &cobra.Command{
		Use:   "doctor",
		Short: "Run end-to-end healthcheck across the vm-claw stack",
		RunE: func(cmd *cobra.Command, args []string) error {
			out := cmd.OutOrStdout()
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}

			// Read BlueBubbles password from ~/.hermes/.env if present so
			// auth-required checks can run; if absent, those checks SKIP.
			password := readBBPasswordFromEnvFile(filepath.Join(home, ".hermes", ".env"))

			fmt.Fprintln(out, "vmclaw doctor")
			failed := doctor.Run(cmd.Context(), out, doctor.Config{
				Executor:      vm.DefaultExecutor,
				VMName:        vmName,
				BBPort:        defaultBBPort,
				BBPassword:    password,
				HermesGateway: "hermes",
			})
			if failed > 0 {
				return fmt.Errorf("%d check(s) FAILED", failed)
			}
			fmt.Fprintln(out, "[OK]    all checks passing")
			return nil
		},
	}
	rootCmd.AddCommand(doctorCmd)
}

// readBBPasswordFromEnvFile is a permissive helper; returns empty string
// on any error so doctor degrades to SKIP for auth-required rows rather
// than failing.
func readBBPasswordFromEnvFile(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		idx := strings.Index(line, "=")
		if idx <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		if key == "BLUEBUBBLES_PASSWORD" { // intentionally hardcoded — must match envfile.go's BluebubblesPasswordKey value
			return strings.TrimSpace(line[idx+1:])
		}
	}
	return ""
}
```

- [ ] **Step 2: Build + smoke test**

```bash
make build
./bin/vmclaw doctor --help
./bin/vmclaw doctor              # will FAIL most rows (nothing set up); intentional
```

Expected: help works; bare `doctor` runs and prints OK/FAIL/SKIP rows. Exit code non-zero when any FAIL.

- [ ] **Step 3: Run tests**

```bash
make test
```

Expected: existing tests pass.

- [ ] **Step 4: Commit**

```bash
git add internal/cli/doctor.go
git commit -m "$(cat <<'EOF'
Add `vmclaw doctor` command

Reads BLUEBUBBLES_PASSWORD from ~/.hermes/.env if present (else
auth-dependent checks SKIP). Runs the full healthcheck row set;
exits non-zero when any row FAILs.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task F.4: `vmclaw bootstrap` orchestrator

**Files:**
- Create: `internal/cli/bootstrap.go`

The most behaviorally complex piece. Two subcommands: `bootstrap` (pre-Phase-2) and `bootstrap finalize` (post-Phase-2).

- [ ] **Step 1: Implement `internal/cli/bootstrap.go`**

Path: `/Users/gintini/s/vm-claw/internal/cli/bootstrap.go`

```go
package cli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/intinig/vm-claw/internal/doctor"
	"github.com/intinig/vm-claw/internal/hermes"
	"github.com/intinig/vm-claw/internal/launchagent"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
)

func init() {
	bootstrapCmd := &cobra.Command{
		Use:   "bootstrap",
		Short: "Run all automatable pre-Phase-2 setup steps",
		Long: "Bootstrap creates the bridge VM, bootstraps the Hermes Docker stack, " +
			"installs the auto-start LaunchAgent, generates the BlueBubbles webhook secret, " +
			"and prints the manual Phase 2 runbook. Safe to re-run.",
		RunE: runBootstrap,
	}

	bootstrapFinalizeCmd := &cobra.Command{
		Use:   "finalize",
		Short: "Run all post-Phase-2 wiring + final healthcheck",
		Long:  "Reads stashed webhook secret, prompts for BlueBubbles password, writes ~/.hermes/.env, restarts the Hermes gateway with --add-host, runs doctor.",
		RunE:  runBootstrapFinalize,
	}

	bootstrapCmd.AddCommand(bootstrapFinalizeCmd)
	rootCmd.AddCommand(bootstrapCmd)
}

func runBootstrap(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	out := cmd.OutOrStdout()

	fmt.Fprintln(out, "==> Checking prerequisites")
	if _, err := exec.LookPath("tart"); err != nil {
		return fmt.Errorf("tart not on PATH (brew install cirruslabs/cli/tart)")
	}
	if _, err := exec.LookPath("softnet"); err != nil {
		return fmt.Errorf("softnet not on PATH (brew install cirruslabs/cli/softnet)")
	}
	if err := vm.VmnetCollisionCheck(); err != nil {
		return err
	}
	fmt.Fprintln(out, "[OK]    prerequisites")

	fmt.Fprintln(out, "==> Creating bridge VM")
	tart := vm.NewTart()
	exists, err := tart.Exists(ctx, defaultVMName)
	if err != nil {
		return err
	}
	if exists {
		fmt.Fprintf(out, "[SKIP]  VM %q already exists\n", defaultVMName)
	} else {
		fmt.Fprintf(out, "[DOING] tart clone %s %s\n", defaultBaseImage, defaultVMName)
		if err := tart.Clone(ctx, defaultBaseImage, defaultVMName); err != nil {
			return err
		}
		fmt.Fprintf(out, "[OK]    VM %q ready\n", defaultVMName)
	}

	fmt.Fprintln(out, "==> Bootstrapping Hermes host stack")
	if err := hermes.EnsureBrewInstalled(ctx, vm.DefaultExecutor); err != nil {
		return err
	}
	if err := hermes.EnsurePackagesInstalled(ctx, vm.DefaultExecutor, "colima", "docker", "docker-compose"); err != nil {
		return err
	}
	if err := hermes.NewColima().Start(ctx, hermes.DefaultColimaConfig()); err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	hcfg := hermes.DefaultHermesConfig(home)
	if err := hermes.NewDocker().PullImage(ctx, hcfg.Image); err != nil {
		return err
	}
	if err := hermes.NewDocker().PullImage(ctx, hcfg.SandboxImage); err != nil {
		return err
	}
	if err := os.MkdirAll(hcfg.HermesHome, 0o700); err != nil {
		return err
	}
	if err := hermes.NewDocker().EnsureNetwork(ctx, hcfg.Network); err != nil {
		return err
	}
	fmt.Fprintln(out, "[OK]    hermes bootstrap")

	fmt.Fprintln(out, "==> Installing bridge-vm LaunchAgent")
	tartPath, err := exec.LookPath("tart")
	if err != nil {
		return err
	}
	if err := launchagent.Install(ctx, vm.DefaultExecutor, home, launchagent.Options{
		Label:    launchagent.DefaultLabel,
		TartPath: tartPath,
		VMName:   defaultVMName,
	}); err != nil {
		return err
	}
	fmt.Fprintln(out, "[OK]    LaunchAgent loaded")

	fmt.Fprintln(out, "==> Generating BlueBubbles webhook secret")
	secretPath := filepath.Join(hcfg.HermesHome, ".bb-webhook-secret")
	secret, err := hermes.EnsureSecret(secretPath)
	if err != nil {
		return err
	}
	fmt.Fprintf(out, "[OK]    secret stashed at %s\n", secretPath)

	printPhase2Runbook(out, secret, secretPath)
	return nil
}

func printPhase2Runbook(out interface {
	Write([]byte) (int, error)
}, secret, secretPath string) {
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "================================================================")
	fmt.Fprintln(out, "==> Pre-Phase-2 setup complete. NEXT STEP: manual VM provisioning.")
	fmt.Fprintln(out, "================================================================")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "1. Wait for the LaunchAgent to boot the VM (next user login)")
	fmt.Fprintln(out, "   OR run `vmclaw vm run` in another terminal now.")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "2. Inside the VM, complete the runbook in")
	fmt.Fprintln(out, "   docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md#vm-provisioning-runbook")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "3. When configuring BlueBubbles' webhook (step D.8), use this exact value")
	fmt.Fprintln(out, "   for the `Authorization: Bearer` header:")
	fmt.Fprintln(out, "")
	fmt.Fprintf(out, "       Bearer %s\n", secret)
	fmt.Fprintf(out, "       (also stashed at %s)\n", secretPath)
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "4. When BlueBubbles is up and the webhook is configured, return here and run:")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "       vmclaw bootstrap finalize")
	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "================================================================")
}

func runBootstrapFinalize(cmd *cobra.Command, _ []string) error {
	ctx := cmd.Context()
	out := cmd.OutOrStdout()

	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	secretPath := filepath.Join(home, ".hermes", ".bb-webhook-secret")
	if _, err := os.Stat(secretPath); os.IsNotExist(err) {
		return fmt.Errorf("missing %s — run `vmclaw bootstrap` first", secretPath)
	}

	tart := vm.NewTart()
	ip, err := tart.IP(ctx, defaultVMName)
	if err != nil {
		return err
	}
	if ip == "" {
		return fmt.Errorf("VM %q not running (load LaunchAgent or run `vmclaw vm run` first)", defaultVMName)
	}

	fmt.Fprintln(out, "==> Probing BlueBubbles liveness")
	if err := probeBlueBubblesLiveness(ctx, ip, defaultBBPort); err != nil {
		return fmt.Errorf("BlueBubbles not reachable at %s:%d (Phase 2 incomplete?): %w", ip, defaultBBPort, err)
	}
	fmt.Fprintln(out, "[OK]    BlueBubbles responding")

	fmt.Fprintln(out, "==> Wiring Hermes BlueBubbles connector")
	if err := runHermesWireCmd(ctx, out, ip); err != nil {
		return err
	}

	fmt.Fprintln(out, "==> Running doctor")
	failed := doctor.Run(ctx, out, doctor.Config{
		Executor:      vm.DefaultExecutor,
		VMName:        defaultVMName,
		BBPort:        defaultBBPort,
		BBPassword:    readBBPasswordFromEnvFile(filepath.Join(home, ".hermes", ".env")),
		HermesGateway: "hermes",
	})
	if failed > 0 {
		return fmt.Errorf("%d check(s) FAILED — finalize incomplete", failed)
	}
	fmt.Fprintln(out, "[OK]    bootstrap complete")
	return nil
}

// probeBlueBubblesLiveness uses the same auth-using endpoint as
// probeBlueBubblesAuth, but with no password (expecting 401 to mean
// "BB is up, password missing", treated as a success here).
//
// Confirm against current BlueBubbles docs at implementation time —
// if a public auth-less endpoint exists, switch this to use it.
func probeBlueBubblesLiveness(ctx context.Context, ip string, port int) error {
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	url := fmt.Sprintf("http://%s:%d/api/v1/server/info", ip, port)
	req, err := http.NewRequestWithContext(cctx, "GET", url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	// 200, 401, 403 all mean "BB is up and accepting requests"
	switch {
	case resp.StatusCode == 200:
		return nil
	case resp.StatusCode == 401 || resp.StatusCode == 403:
		return nil
	default:
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
}

// runHermesWireCmd inlines what `vmclaw hermes wire` would do, with
// the bridge IP already known. Avoids re-resolving the IP and re-
// validating preconditions.
func runHermesWireCmd(ctx context.Context, out io.Writer, ip string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	secret, err := loadSecretOrErr(filepath.Join(home, ".hermes", ".bb-webhook-secret"))
	if err != nil {
		return err
	}
	password, err := promptPassword(out, "BlueBubbles admin password: ")
	if err != nil {
		return err
	}
	if err := probeBlueBubblesAuth(ctx, ip, defaultBBPort, password); err != nil {
		return fmt.Errorf("password rejected by BlueBubbles: %w", err)
	}
	updates := map[string]string{
		hermes.BluebubblesServerURLKey:     "http://bridge-vm:" + fmt.Sprintf("%d", defaultBBPort),
		hermes.BluebubblesPasswordKey:      password,
		hermes.BluebubblesWebhookSecretKey: secret,
	}
	envPath := filepath.Join(home, ".hermes", ".env")
	if err := hermes.UpdateEnvFile(envPath, updates); err != nil {
		return err
	}
	fmt.Fprintf(out, "[OK]    wrote %d keys to %s\n", len(updates), envPath)

	docker := hermes.NewDocker()
	hcfg := hermes.DefaultHermesConfig(home)
	if err := docker.RunHermesGateway(ctx, hcfg, ip); err != nil {
		return err
	}
	fmt.Fprintln(out, "[OK]    Hermes gateway running with --add-host bridge-vm:"+ip)
	return nil
}
```

You'll see this file imports `context`, `io`, `net/http`, `time` for the helpers. Add those imports at the top of the file:

```go
import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/intinig/vm-claw/internal/doctor"
	"github.com/intinig/vm-claw/internal/hermes"
	"github.com/intinig/vm-claw/internal/launchagent"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
)
```

- [ ] **Step 2: Build + smoke test**

```bash
make build
./bin/vmclaw bootstrap --help
./bin/vmclaw bootstrap finalize --help
./bin/vmclaw --help        # confirm bootstrap and finalize show up
```

Expected: clean build. Help text shows bootstrap with finalize as a subcommand.

- [ ] **Step 3: Run tests**

```bash
make test
```

Expected: all existing tests still pass. (The orchestrator's behavior is integration-level; verified at runtime in the next phase, not via unit tests.)

- [ ] **Step 4: Commit**

```bash
git add internal/cli/bootstrap.go
git commit -m "$(cat <<'EOF'
Add `vmclaw bootstrap` + `vmclaw bootstrap finalize`

bootstrap: prereqs check + vm create + hermes bootstrap + LaunchAgent
install + secret generate-or-reuse + Phase 2 runbook print. Safe to
re-run; each step is internally idempotent. Always prints the runbook
so the secret is re-findable.

bootstrap finalize: validates VM running and BlueBubbles reachable;
runs hermes wire (prompts for password, validates against BB API,
writes ~/.hermes/.env, restarts gateway with --add-host); runs doctor
as the final gate. Non-zero exit if doctor finds any FAIL.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase G — Cleanup & documentation

### Task G.1: Delete bash scripts

**Files:**
- Delete: `setup.sh`, `run.sh`, `destroy.sh`, `hermes-setup.sh`

- [ ] **Step 1: Verify the files exist before deleting**

```bash
cd /Users/gintini/s/vm-claw
ls -la setup.sh run.sh destroy.sh hermes-setup.sh
```

Expected: all four files listed.

- [ ] **Step 2: Delete via git**

```bash
git rm setup.sh run.sh destroy.sh hermes-setup.sh
```

Expected: 4 files marked deleted.

- [ ] **Step 3: Verify nothing else still references them**

```bash
grep -rnE 'setup\.sh|run\.sh|destroy\.sh|hermes-setup\.sh' --include='*.go' --include='Makefile' --include='*.md' . 2>&1 | grep -v 'docs/superpowers/' | head -20
```

Expected: no hits in Go code or Makefile. References inside the historical `docs/superpowers/` content are fine — those are deliberately preserved. (Phase G.2 + G.3 update the live docs.)

- [ ] **Step 4: Commit**

```bash
git commit -m "$(cat <<'EOF'
Delete bash scripts superseded by vmclaw CLI

Removes setup.sh, run.sh, destroy.sh, hermes-setup.sh. Their
behavior is now in `vmclaw vm create` / `vmclaw vm run` /
`vmclaw vm destroy` / `vmclaw hermes bootstrap`.

The historical scripts can still be inspected via the
openclaw-pivot-start tag.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task G.2: Update `CLAUDE.md` and `README.md`

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Update CLAUDE.md "Recovery paths"**

Find this block in `/Users/gintini/s/vm-claw/CLAUDE.md`:

```
1. **`./host/healthcheck.sh`** — six-line green/red status across the chain.
2. **VM not booting / no IP** — `tart list` and `tart ip bridge-vm`. If the VM exists but has no IP, `./run.sh` is probably not active in any terminal; either run it again or load the LaunchAgent (`./host/install-vm-launchagent.sh`).
```

Replace with:

```
1. **`vmclaw doctor`** — seven-line green/red status across the chain.
2. **VM not booting / no IP** — `tart list` and `tart ip bridge-vm`. If the VM exists but has no IP, run `vmclaw vm run` in another terminal, or `vmclaw vm install-agent` to load the LaunchAgent.
```

Also, in the same section (`## Recovery paths`), the bullet:

```
6. **VM is unrecoverable / suspect / over-updated** — `./destroy.sh && ./setup.sh && ./run.sh`, then re-run the runbook. The bridge identity's Apple ID is portable; only the local Messages history and BlueBubbles password are lost.
```

becomes:

```
6. **VM is unrecoverable / suspect / over-updated** — `vmclaw vm destroy --yes && vmclaw bootstrap`, then re-run the manual runbook. The bridge identity's Apple ID is portable; only the local Messages history and BlueBubbles password are lost.
```

- [ ] **Step 2: Update CLAUDE.md "Architecture" section**

Find:

```
- `hermes-setup.sh` — Colima + Hermes-image bootstrap (host side).
- `setup.sh` / `run.sh` / `destroy.sh` — Tart VM lifecycle for the iMessage bridge
  VM. Currently still uses the `openclaw` VM name from the previous scope; rename
  is tracked in the design spec.
```

Replace with:

```
- `cmd/vmclaw/main.go` + `internal/` — the `vmclaw` CLI binary that owns Tart VM
  lifecycle (`vmclaw vm <verb>`), Colima/Docker bootstrap (`vmclaw hermes bootstrap`),
  BlueBubbles env wiring (`vmclaw hermes wire`), end-to-end healthchecks
  (`vmclaw doctor`), and the orchestrator (`vmclaw bootstrap` + `vmclaw bootstrap finalize`).
- `Makefile` — `make` to build, `make install` to put the binary on $PATH.
```

- [ ] **Step 3: Update README.md**

Replace the bash invocation examples (the section that shows `./setup.sh && ./run.sh` etc.) with the `vmclaw` equivalents. The exact existing text varies; here's the conceptual replacement:

Locate any block resembling:

```bash
./setup.sh        # download Tahoe base image (~25 GB), create the VM
./run.sh          # boot it with softnet + shared folder
./destroy.sh      # delete it
```

and replace with:

```bash
make install              # build + install vmclaw to ~/go/bin
vmclaw bootstrap          # creates VM, bootstraps Hermes, installs LaunchAgent,
                          # generates webhook secret, prints Phase 2 runbook
# ...do Phase 2 manually inside the VM (Apple ID, Messages.app,
# BlueBubbles install + webhook config — see docs/superpowers/specs/...)
vmclaw bootstrap finalize # writes ~/.hermes/.env, restarts Hermes gateway,
                          # runs doctor
vmclaw doctor             # spot-check anytime
vmclaw vm destroy --yes   # tear down the VM (e.g., to rebuild from scratch)
```

If the README has a tunables table referring to `BRIDGE_VM_NAME` / `COLIMA_*` / `HERMES_*` env vars from the old `hermes-setup.sh`, leave it — the same env vars are honored by the corresponding vmclaw flags' fallbacks.

- [ ] **Step 4: Verify commit-ready state**

```bash
grep -nE '\./setup\.sh|\./run\.sh|\./destroy\.sh|\./hermes-setup\.sh' CLAUDE.md README.md 2>&1 | head -10
```

Expected: no hits. (Or hits only inside backtick-quoted historical references — note any such cases.)

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "$(cat <<'EOF'
Update CLAUDE.md and README.md for vmclaw CLI

- Recovery paths: ./host/healthcheck.sh → vmclaw doctor;
  ./host/install-vm-launchagent.sh → vmclaw vm install-agent;
  ./destroy.sh && ./setup.sh && ./run.sh → vmclaw vm destroy --yes
  && vmclaw bootstrap.
- Architecture: drop the four .sh script lines, add cmd/vmclaw/,
  internal/, Makefile.
- README invocation examples now use vmclaw subcommands. Tunable
  env vars unchanged (vmclaw honors the same names as fallbacks).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task G.3: Append "superseded" notes to prior spec / plan

**Files:**
- Modify: `docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md`
- Modify: `docs/superpowers/plans/2026-05-04-hermes-imessage-bridge-vm.md`

- [ ] **Step 1: Append the note to the bridge-VM spec**

At the very end of `/Users/gintini/s/vm-claw/docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md` (after the last existing line), append:

```markdown

---

**Update 2026-05-04: superseded by `vmclaw` CLI.** The Phase 1.3 script
edits, Phase 3 `--add-host` plumbing, Phase 4 wiring, and Phase 5 polish
in this spec's migration plan are subsumed by the
[`vmclaw` CLI design spec](./2026-05-04-vmclaw-cli-design.md). The
runbook section above (`#vm-provisioning-runbook`) is still
authoritative for the manual Phase 2 work; everything automatable now
lives behind `vmclaw <subcommand>`.
```

- [ ] **Step 2: Append a similar note to the bridge-VM plan**

At the very end of `/Users/gintini/s/vm-claw/docs/superpowers/plans/2026-05-04-hermes-imessage-bridge-vm.md`, append:

```markdown

---

**Update 2026-05-04: superseded by the `vmclaw` CLI plan.** Tasks 0,
1.1, 1.2, 1.3, 1.4, and 3.1 of this plan landed (commits `bfe4842`
through `b264bca` plus `a4ae55a`). The remaining Phase 4.1–4.3 and
Phase 5.1–5.2 tasks are subsumed by
[`docs/superpowers/plans/2026-05-04-vmclaw-cli.md`](./2026-05-04-vmclaw-cli.md):

- 4.1 (research connector key names) → still deferred; output is a
  single commit updating constants in `internal/hermes/envfile.go`.
- 4.2 + 4.3 (`.env` write + e2e test) → folded into
  `vmclaw bootstrap finalize`.
- 5.1 (auto-start LaunchAgent) → `vmclaw vm install-agent`.
- 5.2 (host healthcheck script) → `vmclaw doctor`.
- 5.3 (recovery paths in CLAUDE.md) → already landed in commit
  `eecf46e`.
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-05-04-hermes-imessage-bridge-vm-design.md \
       docs/superpowers/plans/2026-05-04-hermes-imessage-bridge-vm.md
git commit -m "$(cat <<'EOF'
Mark prior bridge-VM spec/plan as superseded by vmclaw CLI

Appends a brief "superseded" note to the prior spec and plan,
linking forward to the vmclaw spec/plan. The historical bodies
stay intact as a record of the migration design before the CLI.
The Phase 2 manual runbook in the prior spec is still authoritative.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Phase H — Deferred research handoff

### Task H.1: Update placeholder constants once Hermes docs confirmed

**This is a documentation-only callout, not an executed task.** Surface here so a future engineer can find it.

The following constants in `internal/hermes/envfile.go` are placeholders:

```go
const (
    BluebubblesServerURLKey     = "BLUEBUBBLES_SERVER_URL"
    BluebubblesPasswordKey      = "BLUEBUBBLES_PASSWORD"
    BluebubblesWebhookSecretKey = "BLUEBUBBLES_WEBHOOK_SECRET"
)
```

Verify against current Hermes docs (https://hermes-agent.nousresearch.com/docs/user-guide/docker — search "BlueBubbles"). When the actual key names are known, update this file with a single small commit:

```bash
# Edit internal/hermes/envfile.go to set the const string values.
git add internal/hermes/envfile.go
git commit -m "Update BlueBubbles connector key names per Hermes docs"
```

Similarly verify `probeBlueBubblesLiveness` in `internal/cli/bootstrap.go` and `probeBlueBubblesAuth` in `internal/cli/hermes.go`. The path `/api/v1/server/info` is widely supported but the auth-less liveness path may differ.

This task is **not** required for the rest of the migration to land — the placeholder names produce a working build with consistent (if speculative) keys. Updating them is a one-line change later.

---

## Self-review notes

Coverage check against the spec:

- **Goal: replace the four bash scripts** → Phase G.1 deletes them.
- **Architecture: Cobra + native Go + Executor injection** → Phase A wires Cobra; Phase B introduces Executor.
- **Two-phase bootstrap** → Phase F.4 task implements it.
- **Webhook secret auto-generated, reused forever** → Phase C.1 (`EnsureSecret`) + Phase F.4 use.
- **Each subcommand internally idempotent** → idempotency tested explicitly in B.1, B.2, C.1, D.1; documented in C.3, C.4, F.* commits.
- **`vmclaw vm create | run | destroy | install-agent | uninstall-agent`** → Phase F.1.
- **`vmclaw hermes bootstrap | wire`** → Phase F.2.
- **`vmclaw doctor`** → Phase F.3.
- **`vmclaw bootstrap` + `vmclaw bootstrap finalize`** → Phase F.4.
- **Project layout `cmd/vmclaw` + `internal/...`** → Phases A.2, B, C, D, E.
- **`make build / install / test / integration / clean`** → Phase A.1.
- **`--version` via `-ldflags`** → Phases A.1 (Makefile) + A.2 (main.go + cli.SetVersion).
- **`internal/launchagent/template.plist` embedded** → Phase D.1.
- **CLAUDE.md / README.md updates** → Phase G.2.
- **Append "superseded" notes to prior spec/plan** → Phase G.3.
- **Deferred Phase 4.1 connector key names** → Phase H.

Placeholder scan (per the writing-plans skill's "No Placeholders" rule):

- Single intentional placeholder is the BlueBubbles connector env var key names in Phase C.2's code, called out explicitly in the constants' doc comment AND in Phase H.1. The plan text itself contains no TBDs / TODOs / "implement later" / "appropriate error handling" / "similar to Task N" patterns.

Type consistency check:

- `vm.NewTart()` and `vm.NewTartWithExecutor(e)` are both defined in B.2 and used consistently in F.* (production calls `NewTart()`).
- `vm.DefaultExecutor` defined in B.2, used in F.*, C.3-C.4, D.1.
- `hermes.UpdateEnvFile`, `hermes.EnsureSecret`, `hermes.DefaultHermesConfig`, `hermes.NewColima`, `hermes.NewDocker`, `hermes.BluebubblesServerURLKey` etc. all defined in C.* and consumed in F.*.
- `launchagent.Install / Uninstall / DefaultLabel / Options / PlistPath` defined in D.1, consumed in F.1 / F.4.
- `doctor.Config / Run / DefaultChecks / Status / Result` defined in E.1, consumed in F.3 / F.4.
- `cli.RootCommand()` defined in A.2 — note: not actually used by the subcommand `init()`s, which use the package-level `rootCmd` directly. That's fine for package-internal access; the `RootCommand()` accessor exists for any future external use. **No bug.**
- `defaultVMName` and `defaultBaseImage` defined in F.1, consumed in F.4.
- `defaultBBPort` defined in F.2, consumed in F.3 / F.4.
- `loadSecretOrErr`, `promptPassword`, `probeBlueBubblesAuth`, `readBBPasswordFromEnvFile` defined once each (F.2 or F.3) and consumed in F.4.
- `probeBlueBubblesLiveness` defined and used only in F.4.

All cross-task references resolve consistently.
