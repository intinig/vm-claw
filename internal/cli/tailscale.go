package cli

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/intinig/vm-claw/internal/tailscale"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
)

func newTailscaleBootstrapCmd() *cobra.Command {
	var authKey, authKeyFile, tag string
	cmd := &cobra.Command{
		Use:   "tailscale-bootstrap",
		Short: "Install Tailscale inside the VM and lock the firewall down",
		Long: "Installs the tailscale-app cask, runs 'tailscale up' with the given auth key, " +
			"verifies the node joined the tailnet, and enables macOS Application Firewall " +
			"block-all-incoming. Operates inside the VM via 'tart exec'.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx, cancel := context.WithTimeout(cmd.Context(), 10*time.Minute)
			defer cancel()

			key, err := resolveAuthKey(authKey, authKeyFile)
			if err != nil {
				return err
			}

			vmName := envOr("VM_CLAW_VM_NAME", defaultVMName)
			inVM := tartExecExecutor{vmName: vmName}
			out := cmd.OutOrStdout()

			fmt.Fprintln(out, "Installing tailscale-app cask inside VM...")
			if err := tailscale.Install(ctx, inVM); err != nil {
				return fmt.Errorf("tailscale install: %w", err)
			}

			fmt.Fprintln(out, "Running tailscale up...")
			if err := tailscale.Up(ctx, inVM, key, tag); err != nil {
				return err
			}

			s, err := tailscale.QueryStatus(ctx, inVM)
			if err != nil {
				return err
			}
			fmt.Fprintf(out, "Tailscale state=%s host=%s ips=%v\n", s.BackendState, s.Hostname, s.TailscaleIPs)

			fmt.Fprintln(out, "Enabling firewall block-all-incoming...")
			if err := vm.EnableBlockAllIncoming(ctx, inVM); err != nil {
				return fmt.Errorf("enable firewall: %w", err)
			}

			fmt.Fprintln(out, "Done.")
			return nil
		},
	}
	cmd.Flags().StringVar(&authKey, "auth-key", "", "Tailscale auth key (tskey-...). Mutually exclusive with --auth-key-file.")
	cmd.Flags().StringVar(&authKeyFile, "auth-key-file", "", "Path to a file containing the auth key (file read once).")
	cmd.Flags().StringVar(&tag, "tag", "tag:vm-claw", "Tailscale advertise tag for this VM.")
	return cmd
}

func resolveAuthKey(flagVal, filePath string) (string, error) {
	if flagVal != "" && filePath != "" {
		return "", fmt.Errorf("--auth-key and --auth-key-file are mutually exclusive")
	}
	if flagVal != "" {
		return flagVal, nil
	}
	if filePath != "" {
		body, err := os.ReadFile(filePath)
		if err != nil {
			return "", fmt.Errorf("read auth-key-file: %w", err)
		}
		return strings.TrimSpace(string(body)), nil
	}
	return "", fmt.Errorf("--auth-key or --auth-key-file is required")
}

// tartExecExecutor implements vm.Executor by shelling out via `tart exec`.
type tartExecExecutor struct {
	vmName string
}

func (e tartExecExecutor) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	full := append([]string{"exec", e.vmName, "--", name}, args...)
	return vm.DefaultExecutor.Run(ctx, "tart", full...)
}
