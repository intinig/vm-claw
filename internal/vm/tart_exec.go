package vm

import "context"

// TartExec implements Executor by running commands inside a Tart VM
// via `tart exec <vmName> -- <cmd> [args...]`.
// Both internal/cli/tailscale.go and internal/doctor/checks.go use this
// shared type to avoid duplication.
type TartExec struct {
	VMName string
}

// Run executes name with args inside the VM via tart exec.
func (e TartExec) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	full := append([]string{"exec", e.VMName, "--", name}, args...)
	return DefaultExecutor.Run(ctx, "tart", full...)
}
