package hermes

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
)

func TestGenerateSecret_Format(t *testing.T) {
	s, err := generateSecret()
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(s) {
		t.Errorf("expected 64 hex chars, got %q (len %d)", s, len(s))
	}
}

func TestGenerateSecret_Unique(t *testing.T) {
	a, _ := generateSecret()
	b, _ := generateSecret()
	if a == b {
		t.Errorf("two consecutive generateSecret() calls returned identical output: %q", a)
	}
}

func TestPersistAndLoadSecret(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".bb-webhook-secret")

	if err := persistSecret(path, "deadbeef"); err != nil {
		t.Fatalf("persistSecret: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("expected perm 0600, got %o", info.Mode().Perm())
	}

	got, err := loadSecret(path)
	if err != nil {
		t.Fatalf("loadSecret: %v", err)
	}
	if got != "deadbeef" {
		t.Errorf("got %q, want deadbeef", got)
	}
}

func TestLoadSecret_Missing(t *testing.T) {
	_, err := loadSecret(filepath.Join(t.TempDir(), "nope"))
	if err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestEnsureSecret_GeneratesIfAbsent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".bb-webhook-secret")

	s1, err := EnsureSecret(path)
	if err != nil {
		t.Fatalf("EnsureSecret first call: %v", err)
	}
	if len(s1) != 64 {
		t.Errorf("expected 64 hex chars, got len %d", len(s1))
	}
}

func TestEnsureSecret_ReusesExisting(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".bb-webhook-secret")

	s1, _ := EnsureSecret(path)
	s2, _ := EnsureSecret(path)

	if s1 != s2 {
		t.Errorf("EnsureSecret should reuse existing secret; got %q then %q", s1, s2)
	}
}
