package doctor

import "os/exec"

// execLookPath is the real implementation used by the lookPath variable.
// Tests can replace lookPath with a stub.
func execLookPath(name string) (string, error) {
	return exec.LookPath(name)
}
