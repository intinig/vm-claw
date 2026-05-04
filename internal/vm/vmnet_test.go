package vm

import (
	"strings"
	"testing"
)

func TestParseIfconfig(t *testing.T) {
	in := `lo0: flags=8049<UP> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP> mtu 1500
	ether 00:11:22:33:44:55
	inet 192.168.1.50 netmask 0xffffff00 broadcast 192.168.1.255
bridge100: flags=8863<UP> mtu 1500
	options=63<RXCSUM,TXCSUM,TSO4,TSO6>
	ether ce:81:96:00:00:64
	Configuration:
		id 0:0:0:0:0:0 priority 0 hellotime 0 fwddelay 0
	member: vmenet0 flags=3<LEARNING,DISCOVER>
	inet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255
`

	got := parseIfconfig(strings.NewReader(in))

	want := map[string]ifaceInfo{
		"lo0":       {IPv4: "127.0.0.1", IsVmnetBridge: false},
		"en0":       {IPv4: "192.168.1.50", IsVmnetBridge: false},
		"bridge100": {IPv4: "192.168.64.1", IsVmnetBridge: true},
	}

	if len(got) != len(want) {
		t.Fatalf("expected %d interfaces, got %d: %#v", len(want), len(got), got)
	}
	for name, w := range want {
		g, ok := got[name]
		if !ok {
			t.Errorf("missing interface %q", name)
			continue
		}
		if g.IPv4 != w.IPv4 || g.IsVmnetBridge != w.IsVmnetBridge {
			t.Errorf("iface %q: got %#v want %#v", name, g, w)
		}
	}
}

func TestDetectVmnetCollision_NoCollision(t *testing.T) {
	ifaces := map[string]ifaceInfo{
		"en0":       {IPv4: "192.168.1.50"},
		"bridge100": {IPv4: "192.168.64.1", IsVmnetBridge: true},
	}
	if err := detectVmnetCollision(ifaces); err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
}

func TestDetectVmnetCollision_Collision(t *testing.T) {
	// vmnet bridge subnet 192.168.64.x collides with en0 on 192.168.64.x
	ifaces := map[string]ifaceInfo{
		"en0":       {IPv4: "192.168.64.10"},
		"bridge100": {IPv4: "192.168.64.1", IsVmnetBridge: true},
	}
	err := detectVmnetCollision(ifaces)
	if err == nil {
		t.Fatal("expected collision error, got nil")
	}
	if !strings.Contains(err.Error(), "vmnet subnet collides") {
		t.Errorf("error should mention 'vmnet subnet collides', got %q", err)
	}
	if !strings.Contains(err.Error(), "en0") {
		t.Errorf("error should name the colliding interface en0, got %q", err)
	}
}

func TestDetectVmnetCollision_NoBridge(t *testing.T) {
	// No vmnet bridge present → can't detect; no error.
	ifaces := map[string]ifaceInfo{
		"en0": {IPv4: "192.168.1.50"},
	}
	if err := detectVmnetCollision(ifaces); err != nil {
		t.Fatalf("expected no error when vmnet bridge absent, got %v", err)
	}
}

func TestDetectVmnetCollision_LoopbackIgnored(t *testing.T) {
	// Loopback 127.0.0.1 should never be flagged as a collision source.
	ifaces := map[string]ifaceInfo{
		"lo0":       {IPv4: "127.0.0.1"},
		"bridge100": {IPv4: "192.168.64.1", IsVmnetBridge: true},
	}
	if err := detectVmnetCollision(ifaces); err != nil {
		t.Fatalf("loopback shouldn't cause collision, got %v", err)
	}
}
