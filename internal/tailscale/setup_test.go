package tailscale

import (
	"context"
	"errors"
	"strings"
	"testing"
)

type fakeExec struct {
	calls   []string
	outputs map[string]string
	errs    map[string]error
}

func (f *fakeExec) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := name + " " + strings.Join(args, " ")
	f.calls = append(f.calls, cmd)
	if err, ok := f.errs[cmd]; ok {
		return nil, err
	}
	return []byte(f.outputs[cmd]), nil
}

func TestStatus_Joined(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{
		"tailscale status --json": `{"BackendState":"Running","Self":{"HostName":"vm-claw","TailscaleIPs":["100.64.1.5"]}}`,
	}}
	s, err := QueryStatus(context.Background(), fx)
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if s.BackendState != "Running" {
		t.Fatalf("BackendState = %q, want Running", s.BackendState)
	}
	if s.Hostname != "vm-claw" {
		t.Fatalf("Hostname = %q, want vm-claw", s.Hostname)
	}
	if len(s.TailscaleIPs) != 1 || s.TailscaleIPs[0] != "100.64.1.5" {
		t.Fatalf("TailscaleIPs = %v, want [100.64.1.5]", s.TailscaleIPs)
	}
}

func TestStatus_NotJoined(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{
		"tailscale status --json": `{"BackendState":"NeedsLogin"}`,
	}}
	s, err := QueryStatus(context.Background(), fx)
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if s.BackendState != "NeedsLogin" {
		t.Fatalf("BackendState = %q, want NeedsLogin", s.BackendState)
	}
}

func TestUp_NoAuthKey_Errors(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{}}
	err := Up(context.Background(), fx, "", "tag:vm-claw")
	if !errors.Is(err, ErrAuthKeyRequired) {
		t.Fatalf("expected ErrAuthKeyRequired, got %v", err)
	}
}

func TestUp_PassesAuthKeyAndTag(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{}}
	if err := Up(context.Background(), fx, "tskey-auth-XYZ", "tag:vm-claw"); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	got := strings.Join(fx.calls, " | ")
	if !strings.Contains(got, "--auth-key=tskey-auth-XYZ") {
		t.Fatalf("expected auth-key in call, got: %s", got)
	}
	if !strings.Contains(got, "--advertise-tags=tag:vm-claw") {
		t.Fatalf("expected advertise-tags in call, got: %s", got)
	}
	if strings.Contains(got, "--ssh") {
		t.Fatalf("--ssh must not be passed (sandboxed Tailscale GUI build rejects it), got: %s", got)
	}
}

func TestUp_RedactsAuthKeyOnError(t *testing.T) {
	authKey := "tskey-auth-SECRET"
	fx := &fakeExec{
		outputs: map[string]string{},
		errs: map[string]error{
			"tailscale up --auth-key=" + authKey + " --advertise-tags=tag:vm-claw": errors.New("backend " + authKey + " failed"),
		},
	}
	err := Up(context.Background(), fx, authKey, "tag:vm-claw")
	if err == nil {
		t.Fatal("expected error")
	}
	if strings.Contains(err.Error(), authKey) {
		t.Fatalf("auth key leaked in error: %v", err)
	}
}
