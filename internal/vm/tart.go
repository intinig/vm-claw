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
