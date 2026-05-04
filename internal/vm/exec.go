package vm

import (
	"bytes"
	"context"
	"os/exec"
)

// Executor runs an external command and returns its combined stdout.
// Production code uses execShellOut; tests inject fakeExecutor.
type Executor interface {
	Run(ctx context.Context, name string, args ...string) ([]byte, error)
}

// execShellOut is the production Executor. It runs the command and returns
// captured stdout. stderr is captured into the error on non-zero exit.
type execShellOut struct{}

func (execShellOut) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return stdout.Bytes(), &execError{name: name, args: args, stderr: stderr.String(), err: err}
	}
	return stdout.Bytes(), nil
}

// execError wraps an exec failure with the captured stderr — easier to
// debug than a bare `exit status 1`.
type execError struct {
	name   string
	args   []string
	stderr string
	err    error
}

func (e *execError) Error() string {
	if e.stderr != "" {
		return e.name + ": " + e.err.Error() + ": " + e.stderr
	}
	return e.name + ": " + e.err.Error()
}

func (e *execError) Unwrap() error { return e.err }

// DefaultExecutor is the production Executor. Use this in normal code paths.
var DefaultExecutor Executor = execShellOut{}
