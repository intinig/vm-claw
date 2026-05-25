package cli

import (
	"fmt"

	"github.com/intinig/vm-claw/internal/doctor"
	"github.com/intinig/vm-claw/internal/vm"
	"github.com/spf13/cobra"
)

// defaultBBPort is a leftover BlueBubbles port — used by a check that
// Batch 9 (Task A7) will remove. Do not propagate.
const defaultBBPort = 1234

func init() {
	doctorCmd := &cobra.Command{
		Use:   "doctor",
		Short: "Run end-to-end healthcheck across the vm-claw stack",
		RunE: func(cmd *cobra.Command, args []string) error {
			out := cmd.OutOrStdout()
			ctx := cmd.Context()

			fmt.Fprintln(out, "vmclaw doctor")
			failed := doctor.Run(ctx, out, doctor.Config{
				Executor: vm.DefaultExecutor,
				VMName:   vmName,
				BBPort:   defaultBBPort,
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
