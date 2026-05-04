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
