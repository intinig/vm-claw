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

// Status is the subset of `tailscale status --json` fields we care about.
type Status struct {
	BackendState string
	Hostname     string
	TailscaleIPs []string
}

// Install ensures the open-source `tailscale` formula is present and the
// tailscaled daemon is registered as a root LaunchDaemon via `brew services`.
// Idempotent.
//
// Why the formula, not the cask:
//   - The cask (`tailscale-app`) installs a sandboxed GUI build whose
//     userspace network extension collides with sshd's privsep socket
//     handoff on macOS — incoming TCP to sshd over the tailnet0 interface
//     fails with `getpeername: Invalid argument` and `Connection reset by
//     peer`, breaking ops SSH over the tailnet entirely.
//   - The formula (`tailscale`) installs the open-source `tailscale` +
//     `tailscaled` binaries; running tailscaled as a root LaunchDaemon
//     sidesteps the sandbox and restores SSH-over-tailnet.
//   - The formula also avoids the one-time "Allow system extension" GUI
//     click that the cask requires on macOS Sequoia.
func Install(ctx context.Context, exec vm.Executor) error {
	if err := vm.EnsureBrewPackages(ctx, exec, "tailscale"); err != nil {
		return err
	}
	// Register tailscaled as a root LaunchDaemon. The brew formula's
	// Caveats describe this exact incantation. Idempotent: brew services
	// start is a no-op if the service is already running.
	if _, err := exec.Run(ctx, "sudo", "brew", "services", "start", "tailscale"); err != nil {
		return fmt.Errorf("brew services start tailscale: %w", err)
	}
	return nil
}

// Up runs `sudo tailscale up` with the given auth key and tag.
// sudo is required because tailscaled runs as root and `tailscale up`
// must talk to it through a root-owned local API socket.
// Auth key value is redacted from any wrapped error.
func Up(ctx context.Context, exec vm.Executor, authKey, advertiseTag string) error {
	if authKey == "" {
		return ErrAuthKeyRequired
	}
	args := []string{
		"tailscale",
		"up",
		"--auth-key=" + authKey,
	}
	if advertiseTag != "" {
		args = append(args, "--advertise-tags="+advertiseTag)
	}
	if _, err := exec.Run(ctx, "sudo", args...); err != nil {
		return redactAuthKey(fmt.Errorf("tailscale up: %w", err), authKey)
	}
	return nil
}

// QueryStatus returns the current tailscale state by parsing
// `tailscale status --json`. The function name avoids a collision with the
// Status type.
func QueryStatus(ctx context.Context, exec vm.Executor) (Status, error) {
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
