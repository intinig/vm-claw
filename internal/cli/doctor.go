package cli

import (
	"fmt"

	"github.com/intinig/vm-claw/internal/doctor"
	"github.com/spf13/cobra"
)

func init() {
	var smoke bool
	var tailnetHost string

	doctorCmd := &cobra.Command{
		Use:   "doctor",
		Short: "Run end-to-end healthcheck across the vm-claw stack",
		RunE: func(cmd *cobra.Command, args []string) error {
			out := cmd.OutOrStdout()
			ctx := cmd.Context()

			cfg := doctor.DefaultConfig()
			cfg.VMName = vmName
			cfg.SmokeEnabled = smoke
			cfg.TailnetHostname = tailnetHost

			fmt.Fprintln(out, "vmclaw doctor")
			failed := doctor.Run(ctx, out, cfg)
			if failed > 0 {
				return fmt.Errorf("%d check(s) FAILED", failed)
			}
			fmt.Fprintln(out, "[OK]    all checks passing")
			return nil
		},
	}
	doctorCmd.PersistentFlags().StringVar(&vmName, "name", envOr("BRIDGE_VM_NAME", defaultVMName), "VM name")
	doctorCmd.Flags().BoolVar(&smoke, "smoke", false, "Include iMessage round-trip smoke-test placeholder")
	doctorCmd.Flags().StringVar(&tailnetHost, "tailnet-host", "", "Tailscale FQDN of VM for reachability probe (e.g. vm-claw.tail-abcdef.ts.net)")
	rootCmd.AddCommand(doctorCmd)
}
