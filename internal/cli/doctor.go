package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/intinig/vm-claw/internal/doctor"
	"github.com/intinig/vm-claw/internal/hermes"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
)

func init() {
	doctorCmd := &cobra.Command{
		Use:   "doctor",
		Short: "Run end-to-end healthcheck across the vm-claw stack",
		RunE: func(cmd *cobra.Command, args []string) error {
			out := cmd.OutOrStdout()
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}

			// Read BlueBubbles password from ~/.hermes/.env if present so
			// auth-required checks can run; if absent, those checks SKIP.
			password := readBBPasswordFromEnvFile(filepath.Join(home, ".hermes", ".env"))

			fmt.Fprintln(out, "vmclaw doctor")
			failed := doctor.Run(cmd.Context(), out, doctor.Config{
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
	rootCmd.AddCommand(doctorCmd)
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
