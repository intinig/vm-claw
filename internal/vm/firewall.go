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
		{"sudo", firewallBin, "--setallowsigned", "off"},
	}
	for _, args := range steps {
		if _, err := exec.Run(ctx, args[0], args[1:]...); err != nil {
			return fmt.Errorf("%s: %w", strings.Join(args, " "), err)
		}
	}
	return nil
}

// AllowApp adds an app to the firewall allow list and unblocks incoming
// connections to it. Used after EnableBlockAllIncoming to whitelist
// specific apps (e.g. Tailscale).
func AllowApp(ctx context.Context, exec Executor, appPath string) error {
	if _, err := exec.Run(ctx, "sudo", firewallBin, "--add", appPath); err != nil {
		return fmt.Errorf("socketfilterfw --add %s: %w", appPath, err)
	}
	if _, err := exec.Run(ctx, "sudo", firewallBin, "--unblockapp", appPath); err != nil {
		return fmt.Errorf("socketfilterfw --unblockapp %s: %w", appPath, err)
	}
	return nil
}
