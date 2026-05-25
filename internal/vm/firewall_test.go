package vm

import (
	"context"
	"strings"
	"testing"
)

func TestIsBlockAllIncoming_True(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{
		"/usr/libexec/ApplicationFirewall/socketfilterfw --getblockall": "Firewall is set to block all non-essential incoming connections\n",
	}}
	got, err := IsBlockAllIncoming(context.Background(), fx)
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if !got {
		t.Fatalf("expected true")
	}
}

func TestIsBlockAllIncoming_False(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{
		"/usr/libexec/ApplicationFirewall/socketfilterfw --getblockall": "Firewall is set to allow incoming connections\n",
	}}
	got, err := IsBlockAllIncoming(context.Background(), fx)
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if got {
		t.Fatalf("expected false")
	}
}

func TestEnableBlockAllIncoming_SetsFlag(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{
		"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on":  "",
		"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setblockall on":     "",
		"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned off": "",
	}}
	if err := EnableBlockAllIncoming(context.Background(), fx); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	got := strings.Join(fx.calls, " | ")
	for _, want := range []string{"--setglobalstate on", "--setblockall on", "--setallowsigned off"} {
		if !strings.Contains(got, want) {
			t.Fatalf("expected %q in calls, got: %s", want, got)
		}
	}
}

func TestAllowApp_AddsAndUnblocks(t *testing.T) {
	const appPath = "/Applications/Tailscale.app"
	fx := &fakeExec{outputs: map[string]string{
		"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add " + appPath:         "",
		"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp " + appPath: "",
	}}
	if err := AllowApp(context.Background(), fx, appPath); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	got := strings.Join(fx.calls, " | ")
	if !strings.Contains(got, "--add "+appPath) || !strings.Contains(got, "--unblockapp "+appPath) {
		t.Fatalf("expected --add and --unblockapp for %s, got: %s", appPath, got)
	}
}
