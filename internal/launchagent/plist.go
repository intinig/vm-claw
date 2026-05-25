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
const DefaultLabel = "com.vm-claw.agent"

//go:embed template.plist
var templateBody string

// Options templated into the plist.
type Options struct {
	Label       string // launchctl Label (also used as the plist filename stem)
	TartPath    string // absolute path to tart binary
	VMName      string // VM name passed to `tart run --net-bridged=<iface>`
	BridgeIface string // host interface for --net-bridged (e.g. "en0")
}

// render templates the plist body. Returns an error if any required
// field is empty.
func render(opts Options) ([]byte, error) {
	if opts.Label == "" || opts.TartPath == "" || opts.VMName == "" || opts.BridgeIface == "" {
		return nil, fmt.Errorf("plist render: Label, TartPath, VMName, and BridgeIface all required (got %#v)", opts)
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
