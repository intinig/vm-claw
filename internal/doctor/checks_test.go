package doctor

import (
	"context"
	"testing"
)

// ── parseSwVersMajor ─────────────────────────────────────────────────────────

func TestParseSwVersMajor_Sequoia(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"15.3.1", 15},
		{"15.0", 15},
		{"26.0.0", 26},
		{"14.6.1", 14},
		{"2", 2},
		{"", 0},
		{"abc", 0},
		{"x.1", 0},
	}
	for _, c := range cases {
		got := parseSwVersMajor(c.in)
		if got != c.want {
			t.Errorf("parseSwVersMajor(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}

// ── smoke placeholder ────────────────────────────────────────────────────────

func TestSmokeCheck_ReturnsWarn(t *testing.T) {
	cfg := DefaultConfig()
	cfg.SmokeEnabled = true

	checks := DefaultChecks(cfg)
	var smokeCheck *Check
	for i, c := range checks {
		if c.Name == "vm-imessage-roundtrip-smoke" {
			smokeCheck = &checks[i].Run
			break
		}
	}
	if smokeCheck == nil {
		t.Fatal("vm-imessage-roundtrip-smoke check not found in DefaultChecks")
	}
	res := (*smokeCheck)(context.Background())
	if res.Status != StatusWarn {
		t.Errorf("smoke check: got Status=%v, want StatusWarn", res.Status)
	}
	if res.Message == "" {
		t.Error("smoke check: expected non-empty Message")
	}
}

func TestSmokeCheck_AbsentWhenDisabled(t *testing.T) {
	cfg := DefaultConfig()
	cfg.SmokeEnabled = false

	checks := DefaultChecks(cfg)
	for _, c := range checks {
		if c.Name == "vm-imessage-roundtrip-smoke" {
			t.Error("smoke check should not appear when SmokeEnabled=false")
		}
	}
}

// ── check count ──────────────────────────────────────────────────────────────

func TestDefaultChecks_Count(t *testing.T) {
	cfg := DefaultConfig()
	checks := DefaultChecks(cfg)
	const wantCount = 20
	if len(checks) != wantCount {
		t.Errorf("DefaultChecks returned %d checks, want %d", len(checks), wantCount)
		for i, c := range checks {
			t.Logf("  [%d] %s", i+1, c.Name)
		}
	}
}

func TestDefaultChecks_CountWithSmoke(t *testing.T) {
	cfg := DefaultConfig()
	cfg.SmokeEnabled = true
	checks := DefaultChecks(cfg)
	const wantCount = 21
	if len(checks) != wantCount {
		t.Errorf("DefaultChecks(smoke) returned %d checks, want %d", len(checks), wantCount)
	}
}
