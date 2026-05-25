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
