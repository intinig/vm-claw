package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/intinig/vm-claw/internal/doctor"
	"github.com/intinig/vm-claw/internal/hermes"
	"github.com/intinig/vm-claw/internal/launchagent"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
)

var doctorFix bool

func init() {
	doctorCmd := &cobra.Command{
		Use:   "doctor",
		Short: "Run end-to-end healthcheck across the vm-claw stack",
		RunE: func(cmd *cobra.Command, args []string) error {
			out := cmd.OutOrStdout()
			ctx := cmd.Context()
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}

			// --fix runs known remediations and exits before the regular
			// healthcheck — the remediations require a reboot, so the
			// post-fix doctor result wouldn't be meaningful in this run.
			if doctorFix {
				return runDoctorFix(ctx, out, home)
			}

			// Read BlueBubbles password from ~/.hermes/.env if present so
			// auth-required checks can run; if absent, those checks SKIP.
			password := readBBPasswordFromEnvFile(filepath.Join(home, ".hermes", ".env"))

			fmt.Fprintln(out, "vmclaw doctor")
			failed := doctor.Run(ctx, out, doctor.Config{
				Executor:      vm.DefaultExecutor,
				VMName:        vmName,
				BBPort:        defaultBBPort,
				BBPassword:    password,
				HermesGateway: "hermes",
			})
			if failed > 0 {
				return fmt.Errorf("%d check(s) FAILED", failed)
			}
			fmt.Fprintln(out, "[OK]    all checks passing")
			return nil
		},
	}
	doctorCmd.PersistentFlags().StringVar(&vmName, "name", envOr("BRIDGE_VM_NAME", defaultVMName), "VM name")
	doctorCmd.Flags().BoolVar(&doctorFix, "fix", false, "Apply known remediations (currently: vmnet bridge subnet collision; requires sudo + reboot)")
	rootCmd.AddCommand(doctorCmd)
}

// runDoctorFix applies the Tahoe vmnet remediation when the bridge100
// subnet collides with the host LAN. No-op (with a friendly message)
// when no collision is detected. Requires sudo; does NOT reboot —
// prints the post-fix instructions instead.
func runDoctorFix(ctx context.Context, out io.Writer, home string) error {
	if err := vm.VmnetCollisionCheck(); err == nil {
		fmt.Fprintln(out, "[SKIP]  no vmnet collision to fix")
		return nil
	} else {
		fmt.Fprintf(out, "==> Detected: %s\n", err)
	}

	fmt.Fprintln(out, "==> Applying Tahoe vmnet remediation (192.168.66.1/24)")
	plistPath := launchagent.PlistPath(home, launchagent.DefaultLabel)
	if _, err := os.Stat(plistPath); err == nil {
		fmt.Fprintf(out, "[DOING] launchctl unload %s\n", plistPath)
		_ = exec.CommandContext(ctx, "launchctl", "unload", plistPath).Run()
	}

	fmt.Fprintln(out, "[DOING] tart stop --all (best-effort)")
	_ = exec.CommandContext(ctx, "tart", "stop", "--all").Run()

	steps := [][]string{
		{"sudo", "rm", "-f", "/var/db/dhcpd_leases"},
		{"sudo", "defaults", "write",
			"/Library/Preferences/SystemConfiguration/com.apple.vmnet",
			"Shared_Net_Address", "-string", "192.168.66.1"},
		{"sudo", "defaults", "write",
			"/Library/Preferences/SystemConfiguration/com.apple.vmnet",
			"Shared_Net_Mask", "-string", "255.255.255.0"},
	}
	for _, s := range steps {
		fmt.Fprintf(out, "[DOING] %s\n", strings.Join(s, " "))
		c := exec.CommandContext(ctx, s[0], s[1:]...)
		c.Stdin, c.Stdout, c.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err := c.Run(); err != nil {
			return fmt.Errorf("%s: %w", strings.Join(s, " "), err)
		}
	}

	fmt.Fprintln(out, "")
	fmt.Fprintln(out, "[OK]    vmnet plist updated and stale leases cleared.")
	fmt.Fprintln(out, "==> REBOOT REQUIRED. After reboot, the LaunchAgent will respawn the VM,")
	fmt.Fprintln(out, "    bridge100 will come up on 192.168.66.0/24, and `vmclaw doctor` should go green.")
	return nil
}

// readBBPasswordFromEnvFile is a permissive helper; returns empty string
// on any error so doctor degrades to SKIP for auth-required rows rather
// than failing.
func readBBPasswordFromEnvFile(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		idx := strings.Index(line, "=")
		if idx <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		if key == hermes.BluebubblesPasswordKey {
			return strings.TrimSpace(line[idx+1:])
		}
	}
	return ""
}
