package vm

import (
	"context"
	"strings"
	"testing"
)

func TestIsFirewallEnabled_True(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{
		"/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate": "Firewall is enabled. (State = 1)\n",
	}}
	got, err := IsFirewallEnabled(context.Background(), fx)
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if !got {
		t.Fatalf("expected true")
	}
}

func TestIsFirewallEnabled_False(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{
		"/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate": "Firewall is disabled. (State = 0)\n",
	}}
	got, err := IsFirewallEnabled(context.Background(), fx)
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	if got {
		t.Fatalf("expected false")
	}
}

func TestEnableFirewall_SetsGlobalAndAllowSigned(t *testing.T) {
	fx := &fakeExec{outputs: map[string]string{
		"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on": "",
		"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setallowsigned on": "",
	}}
	if err := EnableFirewall(context.Background(), fx); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
	got := strings.Join(fx.calls, " | ")
	for _, want := range []string{"--setglobalstate on", "--setallowsigned on"} {
		if !strings.Contains(got, want) {
			t.Fatalf("expected %q in calls, got: %s", want, got)
		}
	}
	// Block-all on socketfilterfw breaks SSH on both bridge and tailnet
	// interfaces even with sshd explicitly allow-listed. Per-interface
	// block belongs to pf (follow-up).
	if strings.Contains(got, "--setblockall on") {
		t.Fatalf("must NOT set --setblockall on (breaks SSH); got: %s", got)
	}
	if strings.Contains(got, "--setallowsigned off") {
		t.Fatalf("must NOT set --setallowsigned off (breaks signed-app inbound including sshd); got: %s", got)
	}
}

func TestAllowApp_AddsAndUnblocks(t *testing.T) {
	const appPath = "/Applications/Tailscale.app"
	fx := &fakeExec{outputs: map[string]string{
		"sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add " + appPath:        "",
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
