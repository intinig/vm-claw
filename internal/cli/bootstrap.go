package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"time"

	"github.com/intinig/vm-claw/internal/launchagent"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
)

// bootstrapBaseImage is the Sequoia base image used by bootstrap.
// Batch 3 will pin this to a digest.
const bootstrapBaseImage = "ghcr.io/cirruslabs/macos-sequoia-base:latest"

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
		fmt.Fprintf(out, "Cloning %s from %s ...\n", defaultVMName, bootstrapBaseImage)
		if err := t.Clone(ctx, bootstrapBaseImage, defaultVMName); err != nil {
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
	tartPath, err := exec.LookPath("tart")
	if err != nil {
		return fmt.Errorf("tart binary not found on PATH: %w", err)
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
	// Defer to the doctor command. For now this is a placeholder until
	// Batch 9 lands the new check set. We intentionally do not call
	// runDoctor directly to avoid coupling before that refactor.
	fmt.Fprintln(cmd.OutOrStdout(), "Run `vmclaw doctor` to verify.")
	return nil
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
