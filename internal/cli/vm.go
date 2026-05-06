package cli

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/intinig/vm-claw/internal/launchagent"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
)

const (
	defaultVMName    = "bridge-vm"
	defaultBaseImage = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
)

var (
	vmName       string
	vmBaseImage  string
	vmDestroyYes bool
	vmAgentLabel string
)

func init() {
	vmCmd := &cobra.Command{
		Use:   "vm",
		Short: "Manage the bridge Tart VM",
	}
	vmCmd.PersistentFlags().StringVar(&vmName, "name", envOr("BRIDGE_VM_NAME", defaultVMName), "VM name")

	vmCreateCmd := &cobra.Command{
		Use:   "create",
		Short: "Clone the Tahoe base image into the bridge VM",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			tart := vm.NewTart()
			exists, err := tart.Exists(ctx, vmName)
			if err != nil {
				return err
			}
			if exists {
				fmt.Fprintf(cmd.OutOrStdout(), "[SKIP]  VM %q already exists\n", vmName)
				return nil
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[DOING] tart clone %s %s\n", vmBaseImage, vmName)
			if err := tart.Clone(ctx, vmBaseImage, vmName); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[OK]    VM %q ready\n", vmName)
			return nil
		},
	}
	vmCreateCmd.Flags().StringVar(&vmBaseImage, "base-image", defaultBaseImage, "Tart base image")

	vmRunCmd := &cobra.Command{
		Use:   "run",
		Short: "Boot the bridge VM with --net-bridged (foreground)",
		RunE: func(cmd *cobra.Command, args []string) error {
			iface, err := resolveBridgeInterface()
			if err != nil {
				return err
			}
			flag := "--net-bridged=" + iface
			fmt.Fprintf(cmd.OutOrStdout(), "[DOING] tart run %s %s\n", flag, vmName)
			tartCmd := exec.CommandContext(cmd.Context(), "tart", "run", flag, vmName)
			tartCmd.Stdin = os.Stdin
			tartCmd.Stdout = os.Stdout
			tartCmd.Stderr = os.Stderr
			return tartCmd.Run()
		},
	}

	vmDestroyCmd := &cobra.Command{
		Use:   "destroy",
		Short: "Delete the bridge VM",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			tart := vm.NewTart()
			exists, err := tart.Exists(ctx, vmName)
			if err != nil {
				return err
			}
			if !exists {
				fmt.Fprintf(cmd.OutOrStdout(), "[SKIP]  VM %q does not exist\n", vmName)
				return nil
			}
			if !vmDestroyYes {
				fmt.Fprintf(cmd.OutOrStdout(), "This will permanently delete the VM %q.\n", vmName)
				fmt.Fprintf(cmd.OutOrStdout(), "Are you sure? [y/N] ")
				reader := bufio.NewReader(os.Stdin)
				answer, _ := reader.ReadString('\n')
				answer = strings.ToLower(strings.TrimSpace(answer))
				if answer != "y" && answer != "yes" {
					fmt.Fprintln(cmd.OutOrStdout(), "Aborted.")
					return nil
				}
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[DOING] tart delete %s\n", vmName)
			if err := tart.Delete(ctx, vmName); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[OK]    VM %q destroyed\n", vmName)
			return nil
		},
	}
	vmDestroyCmd.Flags().BoolVar(&vmDestroyYes, "yes", false, "Skip confirmation prompt")

	vmInstallAgentCmd := &cobra.Command{
		Use:   "install-agent",
		Short: "Install the LaunchAgent that auto-starts the bridge VM at user login",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			tartPath, err := exec.LookPath("tart")
			if err != nil {
				return fmt.Errorf("tart not on PATH; install with `brew install cirruslabs/cli/tart`")
			}
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			label := vmAgentLabel
			if label == "" {
				label = launchagent.DefaultLabel
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[DOING] writing %s\n", launchagent.PlistPath(home, label))
			iface, err := resolveBridgeInterface()
			if err != nil {
				return err
			}
			if err := launchagent.Install(ctx, vm.DefaultExecutor, home, launchagent.Options{
				Label:       label,
				TartPath:    tartPath,
				VMName:      vmName,
				BridgeIface: iface,
			}); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[OK]    LaunchAgent %q loaded (bridged on %s)\n", label, iface)
			return nil
		},
	}
	vmInstallAgentCmd.Flags().StringVar(&vmAgentLabel, "label", "", "LaunchAgent Label (default: "+launchagent.DefaultLabel+")")

	vmUninstallAgentCmd := &cobra.Command{
		Use:   "uninstall-agent",
		Short: "Unload and remove the bridge VM's LaunchAgent",
		RunE: func(cmd *cobra.Command, args []string) error {
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			label := vmAgentLabel
			if label == "" {
				label = launchagent.DefaultLabel
			}
			if err := launchagent.Uninstall(cmd.Context(), vm.DefaultExecutor, home, label); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "[OK]    LaunchAgent %q removed\n", label)
			return nil
		},
	}

	vmCmd.AddCommand(vmCreateCmd, vmRunCmd, vmDestroyCmd, vmInstallAgentCmd, vmUninstallAgentCmd)
	rootCmd.AddCommand(vmCmd)
}

// envOr returns os.Getenv(key) if non-empty, else fallback.
func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// resolveBridgeInterface honors BRIDGE_HOST_IFACE if set, otherwise
// auto-detects via the IPv4 default route. Tart's --net-bridged needs
// the interface name (e.g. "en0"); see CLAUDE.md for why we're on
// bridged mode instead of softnet.
func resolveBridgeInterface() (string, error) {
	if v := os.Getenv("BRIDGE_HOST_IFACE"); v != "" {
		return v, nil
	}
	return vm.DetectBridgeInterface()
}
