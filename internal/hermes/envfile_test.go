package hermes

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseEnvFile_BasicAndComments(t *testing.T) {
	in := `# header comment
FOO=bar
BAZ=qux # not a comment, value runs to EOL
EMPTY=
QUOTED="has spaces"
`
	got := parseEnvFile(in)
	want := map[string]string{
		"FOO":    "bar",
		"BAZ":    "qux # not a comment, value runs to EOL",
		"EMPTY":  "",
		"QUOTED": `"has spaces"`,
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("key %q: got %q, want %q", k, got[k], v)
		}
	}
}

func TestRenderEnvFile_PreservesUnknownLinesAndOrder(t *testing.T) {
	original := `# leading comment
FOO=bar
# section header
BAZ=qux
`
	updates := map[string]string{
		"FOO":    "newbar",
		"NEWVAR": "newval",
	}
	out := renderEnvFile(original, updates)

	// FOO should be updated in place
	if !strings.Contains(out, "FOO=newbar") {
		t.Errorf("expected FOO=newbar in output, got:\n%s", out)
	}
	if strings.Contains(out, "FOO=bar\n") {
		t.Errorf("old FOO=bar should be replaced, got:\n%s", out)
	}
	// BAZ should be unchanged
	if !strings.Contains(out, "BAZ=qux") {
		t.Errorf("unrelated key BAZ should be preserved, got:\n%s", out)
	}
	// Comments preserved
	if !strings.Contains(out, "# leading comment") || !strings.Contains(out, "# section header") {
		t.Errorf("comments should be preserved, got:\n%s", out)
	}
	// New key appended at end
	if !strings.HasSuffix(strings.TrimSpace(out), "NEWVAR=newval") {
		t.Errorf("NEWVAR should be appended at end, got:\n%s", out)
	}
}

func TestRenderEnvFile_EmptyOriginal(t *testing.T) {
	out := renderEnvFile("", map[string]string{"A": "1", "B": "2"})
	// Both keys present
	if !strings.Contains(out, "A=1") || !strings.Contains(out, "B=2") {
		t.Errorf("expected both keys in output, got:\n%s", out)
	}
}

func TestUpdateEnvFile_CreatesIfMissing_Mode600(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")

	if err := UpdateEnvFile(path, map[string]string{"A": "1"}); err != nil {
		t.Fatalf("UpdateEnvFile: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("expected mode 0600, got %o", info.Mode().Perm())
	}

	body, _ := os.ReadFile(path)
	if !strings.Contains(string(body), "A=1") {
		t.Errorf("written file missing key, got:\n%s", body)
	}
}

func TestUpdateEnvFile_PreservesAndUpdates(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ".env")
	if err := os.WriteFile(path, []byte("FOO=bar\nKEEP=me\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := UpdateEnvFile(path, map[string]string{"FOO": "newbar"}); err != nil {
		t.Fatalf("UpdateEnvFile: %v", err)
	}

	body, _ := os.ReadFile(path)
	if !strings.Contains(string(body), "FOO=newbar") {
		t.Errorf("expected FOO=newbar, got:\n%s", body)
	}
	if !strings.Contains(string(body), "KEEP=me") {
		t.Errorf("expected KEEP=me preserved, got:\n%s", body)
	}
}
