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

// Install ensures the tailscale-app cask is present. Idempotent.
// The first launch (to approve the network extension) is a manual GUI step
// documented in docs/runbook-openclaw-install.md.
func Install(ctx context.Context, exec vm.Executor) error {
	return vm.EnsureBrewCask(ctx, exec, "tailscale-app")
}

// Up runs `tailscale up` with the given auth key and tag.
// Auth key value is redacted from any wrapped error.
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
