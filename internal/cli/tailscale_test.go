package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTailscaleBootstrap_NoAuthKey_ReturnsError(t *testing.T) {
	cmd := newTailscaleBootstrapCmd()
	buf := &bytes.Buffer{}
	cmd.SetOut(buf)
	cmd.SetErr(buf)
	cmd.SetArgs([]string{})
	err := cmd.Execute()
	if err == nil {
		t.Fatalf("expected error when no auth key provided")
	}
	if !strings.Contains(err.Error(), "auth-key") {
		t.Fatalf("expected error to mention auth-key, got: %v", err)
	}
}

func TestTailscaleBootstrap_RegistersFlags(t *testing.T) {
	cmd := newTailscaleBootstrapCmd()
	for _, name := range []string{"auth-key", "auth-key-file", "tag"} {
		if f := cmd.Flag(name); f == nil {
			t.Fatalf("expected --%s flag", name)
		}
	}
}

func TestResolveAuthKey_FromFlag(t *testing.T) {
	got, err := resolveAuthKey("tskey-flag", "")
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if got != "tskey-flag" {
		t.Fatalf("got %q, want tskey-flag", got)
	}
}

func TestResolveAuthKey_FromFile(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "key")
	if err := os.WriteFile(p, []byte("tskey-from-file\n"), 0600); err != nil {
		t.Fatal(err)
	}
	got, err := resolveAuthKey("", p)
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if got != "tskey-from-file" {
		t.Fatalf("got %q, want tskey-from-file", got)
	}
}

func TestResolveAuthKey_BothExclusive(t *testing.T) {
	_, err := resolveAuthKey("tskey-flag", "/nonexistent")
	if err == nil || !strings.Contains(err.Error(), "mutually exclusive") {
		t.Fatalf("expected mutually exclusive error, got %v", err)
	}
}

func TestResolveAuthKey_Neither(t *testing.T) {
	_, err := resolveAuthKey("", "")
	if err == nil || !strings.Contains(err.Error(), "required") {
		t.Fatalf("expected required error, got %v", err)
	}
}
