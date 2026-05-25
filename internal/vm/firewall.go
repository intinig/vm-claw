package vm

import (
	"context"
	"fmt"
	"strings"
)

const firewallBin = "/usr/libexec/ApplicationFirewall/socketfilterfw"

// IsFirewallEnabled reports whether the macOS Application Firewall is on
// (any state >= 1). Used by doctor checks.
func IsFirewallEnabled(ctx context.Context, exec Executor) (bool, error) {
	out, err := exec.Run(ctx, firewallBin, "--getglobalstate")
	if err != nil {
		return false, fmt.Errorf("socketfilterfw --getglobalstate: %w", err)
	}
	s := strings.ToLower(string(out))
	// macOS prints either "Firewall is enabled. (State = N)" or
	// "Firewall is disabled. (State = 0)".
	return strings.Contains(s, "enabled"), nil
}

// EnableFirewall turns the macOS Application Firewall on with the default
// signed-software-allowed policy. Inbound for signed apps (sshd, tailscaled,
// imsg, OpenClaw's node binary) is permitted; unsigned listeners are blocked.
// Requires root (sudo).
//
// We intentionally do NOT use `--setblockall on` here: empirically that
// breaks SSH on the bridged LAN AND over the tailnet even with sshd
// explicitly allow-listed, because socketfilterfw's per-app allow-list does
// not reliably honour inbound connections relayed by tailscaled (utun*) or
// inherited across sshd's privilege-separation re-exec. Per-interface
// block-inbound (en0 closed, utun* open) belongs to `pf`, which is a
// follow-up. See spec "Network Posture" section.
func EnableFirewall(ctx context.Context, exec Executor) error {
	steps := [][]string{
		{"sudo", firewallBin, "--setglobalstate", "on"},
		// Allow signed software inbound by default (Apple's signed apps +
		// brew-installed binaries with valid signatures). Unsigned
		// listeners still need explicit --add/--unblockapp.
		{"sudo", firewallBin, "--setallowsigned", "on"},
	}
	for _, args := range steps {
		if _, err := exec.Run(ctx, args[0], args[1:]...); err != nil {
			return fmt.Errorf("%s: %w", strings.Join(args, " "), err)
		}
	}
	return nil
}

// AllowApp adds an app to the firewall allow list and unblocks incoming
// connections to it. Used for unsigned listeners (e.g. development builds)
// that the default signed-allowed policy would otherwise block.
func AllowApp(ctx context.Context, exec Executor, appPath string) error {
	if _, err := exec.Run(ctx, "sudo", firewallBin, "--add", appPath); err != nil {
		return fmt.Errorf("socketfilterfw --add %s: %w", appPath, err)
	}
	if _, err := exec.Run(ctx, "sudo", firewallBin, "--unblockapp", appPath); err != nil {
		return fmt.Errorf("socketfilterfw --unblockapp %s: %w", appPath, err)
	}
	return nil
}
