package vm

import (
	"context"
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

func TestEnsureBrew_AlreadyInstalled(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{"brew --version": "Homebrew 4.0.0\n"}}
	if err := EnsureBrew(context.Background(), fx); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(fx.calls) != 1 || fx.calls[0] != "brew --version" {
		t.Fatalf("expected only brew --version, got %v", fx.calls)
	}
}

func TestEnsureBrewPackages_InstallsMissing(t *testing.T) {
	fx := &fakeExec{
		outputs: map[string]string{
			"brew list --formula imsg":          "",
			"brew install steipete/tap/imsg":    "",
		},
		errs: map[string]error{"brew list --formula imsg": errNotInstalled},
	}
	if err := EnsureBrewPackages(context.Background(), fx, "imsg"); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	got := strings.Join(fx.calls, " | ")
	if !strings.Contains(got, "brew install imsg") {
		t.Fatalf("expected install call, got: %s", got)
	}
}

func TestEnsureBrewCask_Installs(t *testing.T) {
	fx := &fakeExec{
		outputs: map[string]string{
			"brew list --cask tailscale-app":    "",
			"brew install --cask tailscale-app": "",
		},
		errs: map[string]error{"brew list --cask tailscale-app": errNotInstalled},
	}
	if err := EnsureBrewCask(context.Background(), fx, "tailscale-app"); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	got := strings.Join(fx.calls, " | ")
	if !strings.Contains(got, "brew install --cask tailscale-app") {
		t.Fatalf("expected cask install call, got: %s", got)
	}
}
