package launchagent

import (
	"strings"
	"testing"
)

func TestRender_BasicSubstitution(t *testing.T) {
	out, err := render(Options{
		Label:       "com.vm-claw.agent",
		TartPath:    "/opt/homebrew/bin/tart",
		VMName:      "vm-claw",
		BridgeIface: "en0",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"<string>com.vm-claw.agent</string>",
		"<string>/opt/homebrew/bin/tart</string>",
		"<string>--net-bridged=en0</string>",
		"<string>vm-claw</string>",
		"/tmp/com.vm-claw.agent.out.log",
		"/tmp/com.vm-claw.agent.err.log",
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
		{TartPath: "/opt/homebrew/bin/tart", VMName: "vm-claw", BridgeIface: "en0"}, // empty Label
		{Label: "com.vm-claw.x", VMName: "vm-claw", BridgeIface: "en0"},             // empty TartPath
		{Label: "com.vm-claw.x", TartPath: "/opt/homebrew/bin/tart", BridgeIface: "en0"}, // empty VMName
		{Label: "com.vm-claw.x", TartPath: "/opt/homebrew/bin/tart", VMName: "vm-claw"}, // empty BridgeIface
	}
	for i, c := range cases {
		if _, err := render(c); err == nil {
			t.Errorf("case %d: expected error for empty field, got nil", i)
		}
	}
}

func TestRender_VMName(t *testing.T) {
	out, err := render(Options{
		Label:       "com.vm-claw.agent",
		TartPath:    "/opt/homebrew/bin/tart",
		VMName:      "vm-claw",
		BridgeIface: "en0",
	})
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	body := string(out)
	if !strings.Contains(body, "<string>vm-claw</string>") {
		t.Fatalf("expected VMName in plist, got:\n%s", body)
	}
	if strings.Contains(body, "bridge-vm") {
		t.Fatalf("unexpected legacy bridge-vm in plist:\n%s", body)
	}
}
