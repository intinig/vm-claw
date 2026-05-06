package launchagent

import (
	"strings"
	"testing"
)

func TestRender_BasicSubstitution(t *testing.T) {
	out, err := render(Options{
		Label:       "com.vm-claw.bridge-vm",
		TartPath:    "/opt/homebrew/bin/tart",
		VMName:      "bridge-vm",
		BridgeIface: "en0",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"<string>com.vm-claw.bridge-vm</string>",
		"<string>/opt/homebrew/bin/tart</string>",
		"<string>--net-bridged=en0</string>",
		"<string>bridge-vm</string>",
		"/tmp/com.vm-claw.bridge-vm.out.log",
		"/tmp/com.vm-claw.bridge-vm.err.log",
		"/opt/homebrew/bin",
	}
	for _, w := range want {
		if !strings.Contains(string(out), w) {
			t.Errorf("expected output to contain %q, got:\n%s", w, out)
		}
	}
}

func TestRender_RejectsEmptyFields(t *testing.T) {
	cases := []Options{
		{TartPath: "/opt/homebrew/bin/tart", VMName: "bridge-vm", BridgeIface: "en0"}, // empty Label
		{Label: "com.vm-claw.x", VMName: "bridge-vm", BridgeIface: "en0"},             // empty TartPath
		{Label: "com.vm-claw.x", TartPath: "/opt/homebrew/bin/tart", BridgeIface: "en0"}, // empty VMName
		{Label: "com.vm-claw.x", TartPath: "/opt/homebrew/bin/tart", VMName: "bridge-vm"}, // empty BridgeIface
	}
	for i, c := range cases {
		if _, err := render(c); err == nil {
			t.Errorf("case %d: expected error for empty field, got nil", i)
		}
	}
}
