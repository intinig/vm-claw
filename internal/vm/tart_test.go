package vm

import (
	"context"
	"errors"
	"testing"
)

func TestParseTartListContains(t *testing.T) {
	out := `Source Name        Disk Size CPU Memory Running
local  bridge-vm   50      4   8     false
oci    other-vm    50      4   8     true
`
	cases := []struct {
		query string
		want  bool
	}{
		{"bridge-vm", true},
		{"other-vm", true},
		{"missing", false},
		{"", false},
		{"Name", false}, // header row should not count
	}
	for _, tc := range cases {
		if got := parseTartListContains(out, tc.query); got != tc.want {
			t.Errorf("parseTartListContains(%q) = %v, want %v", tc.query, got, tc.want)
		}
	}
}

// fakeExecutor records calls and returns canned responses keyed by argv-joined.
type fakeExecutor struct {
	responses map[string]fakeResp
	calls     []string
}

type fakeResp struct {
	out []byte
	err error
}

func (f *fakeExecutor) Run(_ context.Context, name string, args ...string) ([]byte, error) {
	key := name
	for _, a := range args {
		key += " " + a
	}
	f.calls = append(f.calls, key)
	r, ok := f.responses[key]
	if !ok {
		return nil, errors.New("fakeExecutor: no canned response for " + key)
	}
	return r.out, r.err
}

func TestTart_Exists(t *testing.T) {
	exe := &fakeExecutor{
		responses: map[string]fakeResp{
			"tart list": {out: []byte("Source Name      \nlocal  bridge-vm 50 4 8 false\n"), err: nil},
		},
	}
	tart := NewTartWithExecutor(exe)
	got, err := tart.Exists(context.Background(), "bridge-vm")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got {
		t.Error("expected Exists=true")
	}
	got2, _ := tart.Exists(context.Background(), "missing")
	if got2 {
		t.Error("expected Exists=false for missing")
	}
}

func TestTart_IP_ValidIPv4(t *testing.T) {
	exe := &fakeExecutor{
		responses: map[string]fakeResp{
			"tart ip bridge-vm": {out: []byte("192.168.64.42\n"), err: nil},
		},
	}
	got, err := NewTartWithExecutor(exe).IP(context.Background(), "bridge-vm")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "192.168.64.42" {
		t.Errorf("expected 192.168.64.42, got %q", got)
	}
}

func TestTart_IP_NonIPv4Output(t *testing.T) {
	exe := &fakeExecutor{
		responses: map[string]fakeResp{
			"tart ip bridge-vm": {out: []byte("Error: VM not started\n"), err: nil},
		},
	}
	_, err := NewTartWithExecutor(exe).IP(context.Background(), "bridge-vm")
	if err == nil {
		t.Fatal("expected error for non-IPv4 output, got nil")
	}
}

func TestTart_IP_ErrorReturnsEmpty(t *testing.T) {
	exe := &fakeExecutor{
		responses: map[string]fakeResp{
			"tart ip bridge-vm": {out: nil, err: errors.New("exit 1")},
		},
	}
	got, err := NewTartWithExecutor(exe).IP(context.Background(), "bridge-vm")
	if err != nil {
		t.Errorf("non-zero exit should return empty string, no error; got err=%v", err)
	}
	if got != "" {
		t.Errorf("expected empty IP on tart error, got %q", got)
	}
}

func TestTart_Clone_SkipsIfExists(t *testing.T) {
	exe := &fakeExecutor{
		responses: map[string]fakeResp{
			"tart list": {out: []byte("Source Name\nlocal  bridge-vm 50 4 8 false\n"), err: nil},
		},
	}
	if err := NewTartWithExecutor(exe).Clone(context.Background(), "img", "bridge-vm"); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, c := range exe.calls {
		if c == "tart clone img bridge-vm" {
			t.Error("Clone should have been a no-op when VM exists, but called tart clone")
		}
	}
}
